import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import Observation
import os

// MARK: - Job model

/// Lifecycle states a queue job moves through. The state machine is monotone
/// for terminal states — `completed` / `cancelled` / `failed` are never
/// re-entered.
nonisolated enum QueueJobStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case cancelled
    case failed

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

/// One render job: the recipe (`preset`) + where to write it
/// (`outputBookmark`) + a frozen project snapshot the runner expands into an
/// `AVComposition` at job-start.
///
/// The job is the persistence unit — every field round-trips through
/// `RenderQueueDoc`. The `projectSnapshot` field reuses `ProjectDocument`
/// rather than introducing a parallel snapshot type so the queue inherits the
/// document model's existing schema-versioning + lenient decoding.
///
/// Implicitly MainActor (no `nonisolated` marker) to match the surrounding
/// document model — `ProjectDocument`'s Codable methods are MainActor, so
/// `QueueJob.init(from:)` has to be MainActor too to nest the decode.
/// MainActor structs are Sendable in Swift 6, so cross-task passing still
/// compiles. Equatable rather than Hashable because `ProjectDocument` is only
/// Equatable; nothing in the queue needs a `Set<QueueJob>`.
struct QueueJob: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var preset: ExportPreset
    /// Security-scoped bookmark to the destination URL. App Sandbox does not
    /// grant arbitrary write paths, so the queue keeps the bookmark per job
    /// rather than holding a live URL.
    var outputBookmark: Data
    /// Display-only filename for the inspector list. The bookmark is the
    /// source of truth for the actual write.
    var outputDisplayName: String
    var projectSnapshot: ProjectDocument
    var status: QueueJobStatus
    var progress: Double
    var errorMessage: String?
    /// Wall-clock seconds the job spent in `.running` before its terminal
    /// status. Persisted so the inspector can show "completed in 12.3 s"
    /// across relaunches.
    var runtimeSeconds: Double?

    init(id: UUID = UUID(),
         preset: ExportPreset,
         outputBookmark: Data,
         outputDisplayName: String,
         projectSnapshot: ProjectDocument,
         status: QueueJobStatus = .queued,
         progress: Double = 0,
         errorMessage: String? = nil,
         runtimeSeconds: Double? = nil) {
        self.id = id
        self.preset = preset
        self.outputBookmark = outputBookmark
        self.outputDisplayName = outputDisplayName
        self.projectSnapshot = projectSnapshot
        self.status = status
        self.progress = progress
        self.errorMessage = errorMessage
        self.runtimeSeconds = runtimeSeconds
    }

    var isTerminal: Bool {
        switch status {
        case .completed, .cancelled, .failed: true
        case .queued, .running: false
        }
    }
}

// MARK: - Persistence document

/// Versioned on-disk shape for the queue. A build that opens a newer-version
/// file refuses to overwrite it, matching `ProjectDocument`'s schema-version
/// guard. Implicitly MainActor for the same nested-decode reason as
/// `QueueJob`.
struct RenderQueueDoc: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var jobs: [QueueJob]

    init(version: Int = RenderQueueDoc.currentVersion, jobs: [QueueJob]) {
        self.version = version
        self.jobs = jobs
    }

    private enum CodingKeys: String, CodingKey { case version, jobs }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? RenderQueueDoc.currentVersion
        jobs = try c.decodeIfPresent([QueueJob].self, forKey: .jobs) ?? []
    }
}

// MARK: - Errors

/// Errors surfaced from the run loop. `errorDescription` populates the
/// inspector status pill via `QueueJob.errorMessage`.
nonisolated enum RenderQueueError: Error, LocalizedError {
    case unsupportedCombination(container: String, codec: String)
    case outputDestinationUnavailable
    case compositionEmpty
    case exportSessionCreationFailed
    case writerInitializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCombination(let container, let codec):
            "Container \(container) does not support codec \(codec)."
        case .outputDestinationUnavailable:
            "Output destination unavailable."
        case .compositionEmpty:
            "Nothing to export — the project's timeline is empty."
        case .exportSessionCreationFailed:
            "Could not create an export session for this preset."
        case .writerInitializationFailed(let detail):
            "Could not start the writer: \(detail)"
        }
    }
}

// MARK: - Single-shot resume guard

/// Tiny serialised one-shot flag used by the AVAssetWriter pump to call
/// `continuation.resume()` exactly once. The AVFoundation callback runs on a
/// serial dispatch queue but the compiler doesn't model that, so the
/// `@Sendable` closure can't capture a mutable `var`; this class wraps the
/// state in an unfair lock instead.
private nonisolated final class ResumeBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)

    func tryConsume() -> Bool {
        lock.withLock { resumed in
            if resumed { return false }
            resumed = true
            return true
        }
    }
}

// MARK: - RenderQueue

/// The serial render queue. Owns the in-memory job list, the run loop, the
/// `os_log` audit trail, and the on-disk JSON. UI binds to `jobs`,
/// `currentJobID`, `totalProgress`, `isRunning`, and `statusMessage`.
@Observable
@MainActor
final class RenderQueue {

    /// Ordered jobs, FIFO. Terminal entries (completed / cancelled / failed)
    /// stay in the list until the user clicks "Clear Completed" so they're
    /// visible as a history of recent renders.
    private(set) var jobs: [QueueJob]

    /// The id of the job the runner currently has in flight, or `nil` when
    /// idle. Tracking this on the queue (rather than a property of `QueueJob`)
    /// avoids ambiguity if the user cancels mid-update.
    private(set) var currentJobID: UUID?

    /// Combined `(completed + active.progress) / total` for the bar the
    /// inspector renders above the per-job list.
    private(set) var totalProgress: Double

    /// `true` while the runner Task is alive. Toggling this directly from UI
    /// is allowed only through `start()` / `stop()`.
    private(set) var isRunning: Bool

    /// One-line user-visible status, mirrored into the editor's status bar.
    var statusMessage: String?

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.shenghaoc.LocalCutStudio",
                                category: "render-queue")

    @ObservationIgnored
    private var runnerTask: Task<Void, Never>?

    /// Set when the user cancels the in-flight job; the runner observes this
    /// at every await suspension point and bails out of the current job.
    @ObservationIgnored
    private var cancelInFlightID: UUID?

    /// The currently-running `AVAssetExportSession`, kept so a `cancel(jobID:)`
    /// can call `.cancelExport()` immediately rather than waiting for the run
    /// loop to notice the flag.
    @ObservationIgnored
    private var activeExportSession: AVAssetExportSession?

    /// The currently-running `AVAssetWriter` (fallback path). Same role as
    /// `activeExportSession`.
    @ObservationIgnored
    private var activeWriter: AVAssetWriter?

    /// `persistsToDisk: false` keeps every transition in memory only — tests
    /// rely on this so the suite never mutates the user container's
    /// `queue.json`.
    @ObservationIgnored private let persistsToDisk: Bool

    init(jobs: [QueueJob] = [], persistsToDisk: Bool = true) {
        self.jobs = jobs
        self.currentJobID = nil
        self.totalProgress = 0
        self.isRunning = false
        self.statusMessage = nil
        self.persistsToDisk = persistsToDisk
    }

    // MARK: Enqueue / cancel / clear

    /// Adds a job to the back of the queue and (by default) starts the runner
    /// if idle. Tests pass `autoStart: false` to inspect queue state without
    /// kicking off the export Task.
    func enqueue(_ job: QueueJob, autoStart: Bool = true) {
        guard ExportPreset.isSupportedCombination(container: job.preset.containerFormat,
                                                  codec: job.preset.videoCodec) else {
            var rejected = job
            rejected.status = .failed
            rejected.errorMessage = RenderQueueError.unsupportedCombination(
                container: job.preset.containerFormat,
                codec: job.preset.videoCodec).localizedDescription
            jobs.append(rejected)
            log("job \(job.id.uuidString.prefix(8)) failed — \(rejected.errorMessage ?? "")")
            persist()
            recomputeTotalProgress()
            return
        }
        jobs.append(job)
        log("job \(job.id.uuidString.prefix(8)) enqueued — \(job.preset.name)")
        persist()
        recomputeTotalProgress()
        if autoStart { start() }
    }

    /// Cancels a job by id. Queued jobs flip straight to `.cancelled`; the
    /// running job calls into the active session/writer first so the encode
    /// stops promptly.
    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].status {
        case .queued:
            jobs[index].status = .cancelled
            log("job \(jobID.uuidString.prefix(8)) cancelled (was queued)")
            persist()
            recomputeTotalProgress()
        case .running:
            cancelInFlightID = jobID
            activeExportSession?.cancelExport()
            activeWriter?.cancelWriting()
            // The runner observes the cancel flag and writes the final status.
            log("job \(jobID.uuidString.prefix(8)) cancelling…")
        case .completed, .cancelled, .failed:
            // Cancelling a terminal job is a no-op (R5.4).
            break
        }
    }

    /// Drops every terminal (completed / cancelled / failed) job from the list.
    func clearCompleted() {
        let before = jobs.count
        jobs.removeAll { $0.isTerminal }
        if jobs.count != before {
            persist()
            recomputeTotalProgress()
        }
    }

    // MARK: Runner

    /// Idempotent. Starts the runner Task if there's something to do; a no-op
    /// otherwise.
    func start() {
        guard !isRunning, jobs.contains(where: { $0.status == .queued }) else { return }
        isRunning = true
        runnerTask = Task { [weak self] in
            await self?.runLoop()
            await MainActor.run { self?.isRunning = false }
        }
    }

    /// Cancels the current job (if any) and lets the runner exit on its next
    /// turn. Queued jobs stay queued.
    func stop() {
        if let activeID = currentJobID {
            cancel(jobID: activeID)
        }
        runnerTask?.cancel()
    }

    /// The pull-the-next-job loop. Exits when no `.queued` job remains.
    private func runLoop() async {
        while let next = nextQueuedJobID() {
            await runJob(id: next)
            await Task.yield()
        }
    }

    private func nextQueuedJobID() -> UUID? {
        jobs.first(where: { $0.status == .queued })?.id
    }

    /// Single job's lifecycle: pre-flight checks, build composition, run the
    /// chosen path, update status, persist. Each await suspension is a
    /// cancellation point.
    private func runJob(id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        currentJobID = id
        jobs[index].status = .running
        jobs[index].progress = 0
        jobs[index].errorMessage = nil
        let startWall = Date()
        log("job \(id.uuidString.prefix(8)) running — output: \(jobs[index].outputDisplayName)")
        persist()
        recomputeTotalProgress()

        defer {
            currentJobID = nil
            activeExportSession = nil
            activeWriter = nil
            recomputeTotalProgress()
        }

        // Resolve the output bookmark. A stale / missing target is a clean
        // `.failed` rather than a crash — the user can retry by adding a fresh
        // destination.
        guard let outputURL = resolveBookmark(jobs[index].outputBookmark) else {
            finish(jobID: id, status: .failed,
                   message: RenderQueueError.outputDestinationUnavailable.localizedDescription,
                   startWall: startWall)
            return
        }
        let didStart = outputURL.startAccessingSecurityScopedResource()
        defer { if didStart { outputURL.stopAccessingSecurityScopedResource() } }

        // Build the composition from the snapshot. The runner reconstructs a
        // throwaway `Project` from the document so it can reuse
        // `CompositionBuilder.build(project:)` without touching the editor's
        // live project. Any per-clip security-scoped access taken during
        // reconstruction is released via the `accessedSources` defer below;
        // the queue must not leak access tokens across jobs (R3.4).
        let snapshot = jobs[index].projectSnapshot
        let reconstructed = reconstructProject(from: snapshot)
        let project = reconstructed.project
        let heldSources = reconstructed.accessedSources
        defer { for url in heldSources { url.stopAccessingSecurityScopedResource() } }

        do {
            guard let built = try await CompositionBuilder.build(project: project) else {
                finish(jobID: id, status: .failed,
                       message: RenderQueueError.compositionEmpty.localizedDescription,
                       startWall: startWall)
                return
            }

            if Task.isCancelled || cancelInFlightID == id {
                cancelInFlightID = nil
                finish(jobID: id, status: .cancelled, message: nil, startWall: startWall)
                return
            }

            // Replace any existing file so the writer/session doesn't trip
            // over a stale artefact from a previous run.
            try? FileManager.default.removeItem(at: outputURL)

            let preset = jobs[index].preset
            if let presetName = preset.assetExportSessionPresetName {
                try await exportWithSession(
                    presetName: presetName, preset: preset,
                    built: built, outputURL: outputURL, jobID: id)
            } else {
                try await exportWithWriter(
                    preset: preset, built: built, outputURL: outputURL, jobID: id)
            }

            if cancelInFlightID == id {
                cancelInFlightID = nil
                finish(jobID: id, status: .cancelled, message: nil, startWall: startWall)
                return
            }

            finish(jobID: id, status: .completed, message: nil, startWall: startWall)
        } catch is CancellationError {
            cancelInFlightID = nil
            finish(jobID: id, status: .cancelled, message: nil, startWall: startWall)
        } catch {
            finish(jobID: id, status: .failed,
                   message: error.localizedDescription, startWall: startWall)
        }
    }

    /// Look up the job by id at finish time (rather than caching the index)
    /// so a concurrent `clearCompleted` couldn't shift indices under us.
    private func finish(jobID: UUID, status: QueueJobStatus,
                        message: String?, startWall: Date) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = status
        jobs[index].errorMessage = message
        jobs[index].progress = (status == .completed) ? 1 : jobs[index].progress
        jobs[index].runtimeSeconds = Date().timeIntervalSince(startWall)
        let runtime = jobs[index].runtimeSeconds ?? 0
        switch status {
        case .completed:
            log("job \(jobID.uuidString.prefix(8)) completed in \(String(format: "%.1f", runtime))s")
        case .cancelled:
            log("job \(jobID.uuidString.prefix(8)) cancelled")
        case .failed:
            log("job \(jobID.uuidString.prefix(8)) failed — \(message ?? "")")
        default:
            break
        }
        persist()
    }

    // MARK: AVAssetExportSession path

    private func exportWithSession(presetName: String, preset: ExportPreset,
                                   built: BuiltComposition, outputURL: URL,
                                   jobID: UUID) async throws {
        guard let session = AVAssetExportSession(asset: built.composition,
                                                 presetName: presetName) else {
            throw RenderQueueError.exportSessionCreationFailed
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        activeExportSession = session

        let progressTask = Task { [weak self] in
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let progress) = state {
                    await MainActor.run {
                        self?.updateProgress(jobID: jobID, fraction: progress.fractionCompleted)
                    }
                }
            }
        }
        defer { progressTask.cancel() }

        try await session.export(to: outputURL, as: preset.containerType)
    }

    // MARK: AVAssetWriter path (fallback)

    /// Used when no `AVAssetExportSession` preset matches the recipe. Builds
    /// a writer with the preset's codec + bitrate and pumps the composition
    /// through with an `AVAssetReader`. Only the minimal video / audio
    /// settings dicts are populated — colour management + advanced codec
    /// parameters land here in a future spec.
    private func exportWithWriter(preset: ExportPreset, built: BuiltComposition,
                                  outputURL: URL, jobID: UUID) async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: preset.containerType)
        } catch {
            throw RenderQueueError.writerInitializationFailed(error.localizedDescription)
        }
        activeWriter = writer

        let renderSize = preset.targetSize.cgSize
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: preset.videoCodec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitrate.bitsPerSecond(for: renderSize),
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw RenderQueueError.writerInitializationFailed("Video input rejected for codec \(preset.videoCodec).")
        }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: preset.audioConfig.codec,
            AVSampleRateKey: preset.audioConfig.sampleRate,
            AVNumberOfChannelsKey: preset.audioConfig.channels,
            AVEncoderBitRateKey: preset.audioConfig.bitrate,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        let canAddAudio = writer.canAdd(audioInput)
        if canAddAudio { writer.add(audioInput) }

        let reader = try AVAssetReader(asset: built.composition)
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)

        var readerVideoOutput: AVAssetReaderVideoCompositionOutput?
        if !videoTracks.isEmpty {
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ])
            output.videoComposition = built.videoComposition
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                readerVideoOutput = output
            }
        }

        var readerAudioOutput: AVAssetReaderAudioMixOutput?
        if canAddAudio, !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: nil)
            output.audioMix = built.audioMix
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                readerAudioOutput = output
            }
        }

        guard reader.startReading() else {
            throw RenderQueueError.writerInitializationFailed(
                reader.error?.localizedDescription ?? "reader.startReading failed")
        }
        guard writer.startWriting() else {
            throw RenderQueueError.writerInitializationFailed(
                writer.error?.localizedDescription ?? "writer.startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalDuration = built.duration

        // Pump video then audio sequentially. The writer accepts both inputs
        // out of order so we don't need a task group; the simpler shape avoids
        // wrestling with Sendable conformance of AVFoundation classes inside
        // a concurrent group.
        if let videoOutput = readerVideoOutput {
            await Self.pump(input: videoInput, from: videoOutput,
                            totalDuration: totalDuration) { [weak self] fraction in
                Task { @MainActor in
                    self?.updateProgress(jobID: jobID, fraction: fraction)
                }
            }
        } else {
            videoInput.markAsFinished()
        }

        if let audioOutput = readerAudioOutput {
            await Self.pump(input: audioInput, from: audioOutput,
                            totalDuration: totalDuration, progress: nil)
        } else if canAddAudio {
            audioInput.markAsFinished()
        }

        if cancelInFlightID == jobID {
            writer.cancelWriting()
            return
        }

        await writer.finishWriting()
        if writer.status == .failed, let error = writer.error {
            throw error
        }
    }

    /// Pulls one input dry. The progress callback is `@Sendable` because it's
    /// invoked on the writer's serial dispatch queue, not the MainActor.
    private nonisolated static func pump(
        input: AVAssetWriterInput,
        from output: AVAssetReaderOutput,
        totalDuration: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.shenghaoc.LocalCutStudio.renderqueue.pump")
            let resume = ResumeBox()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        input.append(sample)
                        if let progress, totalDuration > 0 {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            let fraction = max(0, min(1, pts / totalDuration))
                            progress(fraction)
                        }
                    } else {
                        input.markAsFinished()
                        if resume.tryConsume() {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }
    }

    // MARK: Progress / status

    func updateProgress(jobID: UUID, fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].progress = max(0, min(1, fraction))
        recomputeTotalProgress()
    }

    /// `(completed + active.progress) / total` — terminal entries that were
    /// cancelled or failed count as "done" for the bar, so progress is
    /// monotone even when a job aborts.
    private func recomputeTotalProgress() {
        guard !jobs.isEmpty else { totalProgress = 0; return }
        var completed = 0.0
        var active = 0.0
        for job in jobs {
            switch job.status {
            case .completed, .cancelled, .failed:
                completed += 1
            case .running:
                active += max(0, min(1, job.progress))
            case .queued:
                break
            }
        }
        let total = Double(jobs.count)
        totalProgress = (completed + active) / total
    }

    // MARK: Persistence

    /// Sandbox-friendly location: the container's Application Support folder.
    /// App Sandbox grants this directly, so no security-scoped bookmark is
    /// needed for the queue file itself (R3.5). Output URLs do still need
    /// bookmarks because the user picks them outside the container.
    nonisolated static func queueFileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }
        let dir = support.appendingPathComponent("LocalCut Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json", isDirectory: false)
    }

    /// Writes the current queue to disk atomically. Called on every state
    /// transition; the doc is small enough that this is cheap.
    private func persist() {
        guard persistsToDisk, let url = Self.queueFileURL() else { return }
        let doc = RenderQueueDoc(jobs: jobs)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("queue persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the on-disk queue and reconciles state. Called once at app
    /// launch from the editor model.
    func load() {
        guard let url = Self.queueFileURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let doc = try JSONDecoder().decode(RenderQueueDoc.self, from: data)
            // Refuse to overwrite a newer-version file on save (R3.6); the
            // simplest enforcement is to skip loading entirely so the queue
            // stays empty and the file remains untouched until the build
            // catches up.
            guard doc.version <= RenderQueueDoc.currentVersion else {
                statusMessage = "Render queue saved by a newer version — skipping."
                return
            }
            jobs = Self.reconcile(loaded: doc.jobs)
            recomputeTotalProgress()
            log("queue loaded — \(jobs.count) job(s)")
            // Resume the runner if any survived as queued.
            start()
        } catch {
            logger.error("queue load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Implements R3.2 + R3.3: any `running` job rewinds to `queued`; any job
    /// with a now-unresolvable `outputBookmark` flips to `failed`. Pure
    /// function so the same reconciliation can be unit-tested. Implicitly
    /// MainActor so it can touch `QueueJob`'s MainActor-defaulted properties
    /// without the compiler flagging the access.
    static func reconcile(loaded: [QueueJob]) -> [QueueJob] {
        loaded.map { job in
            var copy = job
            if copy.status == .running {
                copy.status = .queued
                copy.progress = 0
                copy.errorMessage = nil
            }
            if copy.status == .queued, !canResolve(bookmark: copy.outputBookmark) {
                copy.status = .failed
                copy.errorMessage = RenderQueueError.outputDestinationUnavailable.localizedDescription
            }
            return copy
        }
    }

    private static func canResolve(bookmark: Data) -> Bool {
        guard !bookmark.isEmpty else { return false }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark,
                         options: [.withSecurityScope],
                         relativeTo: nil,
                         bookmarkDataIsStale: &stale)) != nil
    }

    // MARK: Helpers

    private func resolveBookmark(_ data: Data) -> URL? {
        guard !data.isEmpty else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    /// Builds a throwaway `Project` from a Codable snapshot so the queue can
    /// reuse `CompositionBuilder.build(project:)` without touching the
    /// editor's live project. Returns both the project and the set of URLs
    /// for which the runner now holds security-scoped access — the caller
    /// must `stopAccessingSecurityScopedResource()` on each when the job
    /// finishes (R3.4).
    private func reconstructProject(from doc: ProjectDocument)
        -> (project: Project, accessedSources: [URL]) {
        let project = Project()
        project.name = doc.name
        project.renderSize = CGSize(width: doc.renderWidth, height: doc.renderHeight)
        project.frameRate = doc.frameRate

        // Rebuild media items from refs; failures mean the source file isn't
        // reachable any more and the export's reader will skip those tracks.
        // We intentionally don't surface this through the queue's error path
        // because the user wrote this snapshot in good faith — the composition
        // builder reports the empty composition instead.
        var rebuilt: [MediaItem] = []
        var accessed: [URL] = []
        for ref in doc.media {
            guard !ref.bookmark.isEmpty else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: ref.bookmark,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            }
            let item = MediaItem(url: url, id: ref.id)
            item.name = ref.displayName
            item.duration = ref.duration.cmTime
            item.naturalSize = CGSize(width: ref.naturalWidth, height: ref.naturalHeight)
            item.preferredTransform = ref.preferredTransform.cgTransform
            item.hasVideo = ref.hasVideo
            item.hasAudio = ref.hasAudio
            item.bookmark = ref.bookmark
            rebuilt.append(item)
        }
        project.mediaItems = rebuilt

        project.videoTracks = doc.videoTracks.map { track in
            let runtime = Track(name: track.name.isEmpty ? "V1" : track.name, kind: .video)
            runtime.isMuted = track.isMuted
            runtime.clips = track.clips.map { $0.makeClip() }
            return runtime
        }
        project.audioTracks = doc.audioTracks.map { track in
            let runtime = Track(name: track.name.isEmpty ? "A1" : track.name, kind: .audio)
            runtime.isMuted = track.isMuted
            runtime.clips = track.clips.map { $0.makeClip() }
            return runtime
        }
        if project.videoTracks.isEmpty { project.videoTracks = [Track(name: "V1", kind: .video)] }
        if project.audioTracks.isEmpty { project.audioTracks = [Track(name: "A1", kind: .audio)] }

        project.captionTracks = doc.captionTracks.map { $0.makeTrack() }
        return (project, accessed)
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    // MARK: Convenience entry points

    /// Builds + enqueues a job for the toolbar's Export shortcut, then starts
    /// the runner. The toolbar handler picks the destination URL, captures
    /// a security-scoped bookmark, snapshots the project, and calls this.
    func enqueueWithDefaultPreset(outputURL: URL, project: Project,
                                  bookmark: Data) {
        let snapshot = ProjectDocument(project: project)
        let job = QueueJob(
            preset: BuiltInExportPresets.defaultPreset,
            outputBookmark: bookmark,
            outputDisplayName: outputURL.lastPathComponent,
            projectSnapshot: snapshot)
        enqueue(job)
    }
}
