import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import Observation
import os
import LocalCutCore

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
    case hostNotCapable(String)
    case outputDestinationUnavailable
    case compositionEmpty
    case exportSessionCreationFailed
    case writerInitializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCombination(let container, let codec):
            "Container \(container) does not support codec \(codec)."
        case .hostNotCapable(let reason):
            reason
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

/// Holds the running voice-cleanup DSP state (gate / compressor envelopes)
/// across `requestMediaDataWhenReady` callbacks. No lock is needed — unlike
/// `ResumeBox`, `state` is touched exclusively inside the pump's request block,
/// which AVFoundation invokes serially on `pumpQueue`, and the box never escapes
/// that closure. `@unchecked Sendable` documents that confinement.
private nonisolated final class VoiceCleanupStateBox: @unchecked Sendable {
    var state = VoiceCleanupProcessorState()
}

nonisolated struct BookmarkResolution: Equatable, Sendable {
    let url: URL
    let refreshedBookmark: Data?
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

    @ObservationIgnored
    private var runnerToken: UUID?

    @ObservationIgnored
    private var suppressAutoRestartAfterRunnerStops = false

    @ObservationIgnored
    var runnerDrainedForTesting: (() -> Void)?

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

    @ObservationIgnored
    private let outputBookmarkResolver: @Sendable (Data) -> BookmarkResolution?

    @ObservationIgnored
    private var offlineMeterSink: (@Sendable (AudioMeterSnapshot) -> Void)?

    @ObservationIgnored
    private var offlineMeterActivitySink: (@MainActor (Bool) -> Void)?

    /// Set when `load()` reads a queue file written by a newer build than
    /// this one understands. While true, `persist()` is a no-op so the
    /// newer-version file isn't downconverted by a later enqueue / cancel
    /// (R3.6, codex P1).
    @ObservationIgnored private var refusingPersist: Bool = false

    init(
        jobs: [QueueJob] = [],
        persistsToDisk: Bool = true,
        outputBookmarkResolver: (@Sendable (Data) -> BookmarkResolution?)? = nil
    ) {
        self.jobs = jobs
        self.currentJobID = nil
        self.totalProgress = 0
        self.isRunning = false
        self.statusMessage = nil
        self.persistsToDisk = persistsToDisk
        self.outputBookmarkResolver = outputBookmarkResolver ?? Self.resolveSecurityScopedBookmark
    }

    func setOfflineMeterSink(_ sink: (@Sendable (AudioMeterSnapshot) -> Void)?,
                             activity: (@MainActor (Bool) -> Void)? = nil) {
        offlineMeterSink = sink
        offlineMeterActivitySink = activity
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
        if let hostError = job.preset.hostCapabilityError() {
            var rejected = job
            rejected.status = .failed
            rejected.errorMessage = RenderQueueError.hostNotCapable(hostError).localizedDescription
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

    /// Requeues a terminal job that didn't finish (`.failed` / `.cancelled`) so
    /// the runner picks it up again, reusing the stored snapshot + destination
    /// bookmark — the user keeps the row to retry instead of rebuilding it from
    /// scratch (export-queue R3.3). No-op for `.queued` / `.running` / a job
    /// that already `.completed`.
    func retry(jobID: UUID, autoStart: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].status {
        case .failed, .cancelled:
            jobs[index].status = .queued
            jobs[index].errorMessage = nil
            jobs[index].progress = 0
            jobs[index].runtimeSeconds = nil
            log("job \(jobID.uuidString.prefix(8)) requeued for retry")
            persist()
            recomputeTotalProgress()
            if autoStart { start() }
        case .queued, .running, .completed:
            break
        }
    }

    /// Resolves a job's output URL from its security-scoped bookmark so the
    /// inspector can reveal a finished render in Finder. Returns nil if the
    /// bookmark no longer resolves.
    func outputURL(forJobID jobID: UUID) -> URL? {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              let resolution = resolveBookmark(jobs[index].outputBookmark) else { return nil }
        if let refreshed = resolution.refreshedBookmark {
            jobs[index].outputBookmark = refreshed
            persist()
        }
        return resolution.url
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
        guard jobs.contains(where: { $0.status == .queued }) else { return }
        suppressAutoRestartAfterRunnerStops = false
        guard runnerTask == nil else { return }
        let token = UUID()
        runnerToken = token
        isRunning = true
        runnerTask = Task { [weak self] in
            await self?.runLoop()
            self?.runnerDidFinish(token: token)
        }
    }

    /// Cancels the current job (if any) and lets the runner exit on its next
    /// turn. Queued jobs stay queued.
    func stop() {
        suppressAutoRestartAfterRunnerStops = true
        if let activeID = currentJobID {
            cancel(jobID: activeID)
        }
        runnerTask?.cancel()
    }

    /// The pull-the-next-job loop. Exits when no `.queued` job remains or
    /// the runner task is cancelled — without the cancel check, `stop()`
    /// could cancel the in-flight job and then watch the loop immediately
    /// pull the next queued one (codex P2).
    private func runLoop() async {
        while !Task.isCancelled, let next = nextQueuedJobID() {
            await runJob(id: next)
            await Task.yield()
        }
        if !Task.isCancelled {
            runnerDrainedForTesting?()
        }
    }

    private func runnerDidFinish(token: UUID) {
        guard runnerToken == token else { return }
        runnerTask = nil
        runnerToken = nil
        isRunning = false
        let shouldRestart = !suppressAutoRestartAfterRunnerStops
            && jobs.contains(where: { $0.status == .queued })
        suppressAutoRestartAfterRunnerStops = false
        if shouldRestart {
            start()
        }
    }

    private func nextQueuedJobID() -> UUID? {
        jobs.first(where: { $0.status == .queued })?.id
    }

    /// Single job's lifecycle: pre-flight checks, build composition, run the
    /// chosen path, update status, persist. Each await suspension is a
    /// cancellation point.
    ///
    /// Re-resolves the job by id after every suspension instead of caching
    /// `firstIndex` — `clearCompleted()` (or any other mutator) can drop
    /// earlier rows during an await and shift indices under us (codex P1).
    private func runJob(id: UUID) async {
        guard let initialIndex = jobs.firstIndex(where: { $0.id == id }) else { return }
        currentJobID = id
        let preset = jobs[initialIndex].preset
        let outputBookmark = jobs[initialIndex].outputBookmark
        let outputDisplayName = jobs[initialIndex].outputDisplayName
        let snapshot = jobs[initialIndex].projectSnapshot
        jobs[initialIndex].status = .running
        jobs[initialIndex].progress = 0
        jobs[initialIndex].errorMessage = nil
        let startWall = Date()
        log("job \(id.uuidString.prefix(8)) running — output: \(outputDisplayName)")
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
        guard let outputResolution = resolveBookmark(outputBookmark) else {
            finish(jobID: id, status: .failed,
                   message: RenderQueueError.outputDestinationUnavailable.localizedDescription,
                   startWall: startWall)
            return
        }
        if let refreshed = outputResolution.refreshedBookmark {
            refreshOutputBookmark(jobID: id, bookmark: refreshed)
        }
        let outputURL = outputResolution.url
        let didStart = outputURL.startAccessingSecurityScopedResource()
        defer { if didStart { outputURL.stopAccessingSecurityScopedResource() } }

        // A mid-encode cancel via `AVAssetExportSession.cancelExport()` leaves
        // the partially-written file at the user's path (the writer path cleans
        // up after itself; the session path does not). Delete it on cancel so a
        // cancel never leaves a corrupt artefact behind — an explicit
        // release-readiness gate. `try?` no-ops when the writer already removed it.
        //
        // Guarded by `didBeginEncoding`: until the deliberate overwrite below
        // runs, the file at `outputURL` is the user's *pre-existing* file, so a
        // pre-encode cancel (e.g. cancelled while `CompositionBuilder.build` is
        // still awaiting and throwing `CancellationError`) must not delete it.
        var didBeginEncoding = false
        let removePartialOutput = {
            guard didBeginEncoding else { return }
            _ = try? FileManager.default.removeItem(at: outputURL)
        }

        // Build the composition from the snapshot. The runner reconstructs a
        // throwaway `Project` from the document so it can reuse
        // `CompositionBuilder.build(project:)` without touching the editor's
        // live project. Any per-clip security-scoped access taken during
        // reconstruction is released via the `accessedSources` defer below;
        // the queue must not leak access tokens across jobs (R3.4).
        //
        // The preset's target dimensions / aspect / frame rate override the
        // snapshot's render settings, so queuing the Instagram 9:16 preset
        // against a 1920×1080 project actually renders 1080×1920 — without
        // this step the UI advertises an aspect that the encode wouldn't
        // produce (codex P1).
        //
        // Source-bookmark resolution is expensive on sleeping drives or
        // network shares, so the heavy I/O happens off MainActor; only
        // the `startAccessing` calls and project assembly stay here
        // (Claude review).
        let resolved = await Task.detached(priority: .userInitiated) {
            (
                media: Self.resolveSourceBookmarks(from: snapshot.media),
                overlays: Self.resolveOverlayBookmarks(from: snapshot.overlays)
            )
        }.value
        let refreshedSnapshot = refreshSourceBookmarks(
            in: snapshot,
            jobID: id,
            resolvedMedia: resolved.media,
            resolvedOverlays: resolved.overlays)
        let reconstructed = reconstructProject(from: refreshedSnapshot, applying: preset,
                                               preResolvedMedia: resolved.media,
                                               preResolvedOverlays: resolved.overlays)
        let project = reconstructed.project
        let heldSources = reconstructed.accessedSources
        let missingSources = reconstructed.missingBookmarks
        defer { for url in heldSources { url.stopAccessingSecurityScopedResource() } }

        // If any referenced source bookmark didn't resolve, the export would
        // silently render with clips missing. Better to fail the row so the
        // user knows what to retry (codex P1).
        if missingSources > 0 {
            finish(jobID: id, status: .failed,
                   message: "Could not resolve \(missingSources) source media file(s) — relink and re-queue.",
                   startWall: startWall)
            return
        }

        do {
            let overlaySourceRegistryID = await registerOverlaySources(for: project)
            defer {
                EffectCompositor.releaseOverlaySources(for: overlaySourceRegistryID)
            }
            guard let built = try await CompositionBuilder.build(
                project: project,
                overlaySourceRegistryID: overlaySourceRegistryID) else {
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
            // over a stale artefact from a previous run. Past this point the
            // user's pre-existing file is gone, so a cancel may safely delete
            // whatever the encode wrote.
            try? FileManager.default.removeItem(at: outputURL)
            didBeginEncoding = true

            let hasAudio = !built.composition.tracks(withMediaType: .audio).isEmpty
            let shouldUseWriterForOfflineMeter = offlineMeterSink != nil && hasAudio
            let shouldUseWriterForVoiceCleanup = built.audioCleanup.requiresOfflineProcessing && hasAudio
            let shouldUseWriter = shouldUseWriterForOfflineMeter || shouldUseWriterForVoiceCleanup
            if shouldUseWriterForOfflineMeter {
                offlineMeterActivitySink?(true)
            }
            defer {
                if shouldUseWriterForOfflineMeter {
                    offlineMeterActivitySink?(false)
                }
            }

            if !shouldUseWriter,
               let presetName = preset.assetExportSessionPresetName {
                try await exportWithSession(
                    presetName: presetName, preset: preset,
                    built: built, outputURL: outputURL, jobID: id)
            } else {
                try await exportWithWriter(
                    preset: preset, built: built, outputURL: outputURL, jobID: id)
            }

            if cancelInFlightID == id {
                cancelInFlightID = nil
                removePartialOutput()
                finish(jobID: id, status: .cancelled, message: nil, startWall: startWall)
                return
            }

            finish(jobID: id, status: .completed, message: nil, startWall: startWall)
        } catch is CancellationError {
            cancelInFlightID = nil
            removePartialOutput()
            finish(jobID: id, status: .cancelled, message: nil, startWall: startWall)
        } catch {
            // `AVAssetExportSession.cancelExport()` makes the awaited export
            // throw a generic error, not `CancellationError`. If a cancel is
            // in flight for this job, treat any failure as the cancellation
            // it actually is so the row doesn't persist as `.failed` (codex P2).
            if cancelInFlightID == id {
                cancelInFlightID = nil
                removePartialOutput()
                finish(jobID: id, status: .cancelled, message: nil, startWall: startWall)
            } else {
                finish(jobID: id, status: .failed,
                       message: error.localizedDescription, startWall: startWall)
            }
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
        let displayName = jobs[index].outputDisplayName
        // Mirror the transition into `statusMessage` so the editor status bar
        // reflects completion / cancellation / failure too — the inspector
        // row's pill catches it but a user looking only at the status bar
        // would otherwise see no signal that the export finished (Claude
        // review).
        switch status {
        case .completed:
            log("job \(jobID.uuidString.prefix(8)) completed in \(String(format: "%.1f", runtime))s")
            statusMessage = "Rendered \(displayName) in \(String(format: "%.1f", runtime))s."
        case .cancelled:
            log("job \(jobID.uuidString.prefix(8)) cancelled")
            statusMessage = "Cancelled \(displayName)."
        case .failed:
            log("job \(jobID.uuidString.prefix(8)) failed — \(message ?? "")")
            statusMessage = "Render of \(displayName) failed: \(message ?? "unknown error")"
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
        // The bracket bitrate scales with frame rate too — honour the
        // preset's override, fall back to the composition's nominal video
        // rate, and finally to 30 if neither tells us anything (Claude
        // review).
        let inferredRate = built.composition.tracks(withMediaType: .video)
            .compactMap { Double($0.nominalFrameRate) }
            .first(where: { $0 > 0 }) ?? 30
        let frameRate = preset.frameRate ?? inferredRate
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: preset.videoCodec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitrate.bitsPerSecond(for: renderSize, frameRate: frameRate),
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw RenderQueueError.writerInitializationFailed("Video input rejected for codec \(preset.videoCodec).")
        }
        writer.add(videoInput)

        // Compressed audio needs `AVEncoderBitRateKey`; passing it for LPCM
        // makes `AVAssetWriterInput` refuse to initialise. Cast the format ID
        // explicitly to `Int` so the NSNumber bridge inside the settings
        // dictionary doesn't fall over (Gemini review).
        var audioSettings: [String: Any] = [
            AVFormatIDKey: Int(preset.audioConfig.codec),
            AVSampleRateKey: preset.audioConfig.sampleRate,
            AVNumberOfChannelsKey: preset.audioConfig.channels,
        ]
        if preset.audioConfig.codec != kAudioFormatLinearPCM {
            audioSettings[AVEncoderBitRateKey] = preset.audioConfig.bitrate
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        let canAddAudio = writer.canAdd(audioInput)
        if canAddAudio { writer.add(audioInput) }

        let reader = try AVAssetReader(asset: built.composition)
        // The async `loadTracks(withMediaType:)` requires `AVComposition` to be
        // `sending`, which Swift 6's strict-concurrency check refuses because
        // the composition is reached through a `BuiltComposition` struct and
        // so isn't a uniquely-owned local. The synchronous accessors are
        // soft-deprecated on AVAsset but remain functional and avoid the
        // cross-actor send; for a freshly-built local composition they
        // produce the same tracks.
        //
        // `AVComposition.tracks(withMediaType:)` returns `[AVCompositionTrack]`;
        // the NSArray bridge handles the upcast to `[AVAssetTrack]` that the
        // reader-output initialisers want.
        let videoTracks = built.composition.tracks(withMediaType: .video) as [AVAssetTrack]
        let audioTracks = built.composition.tracks(withMediaType: .audio) as [AVAssetTrack]

        var readerVideoOutput: AVAssetReaderVideoCompositionOutput?
        if !videoTracks.isEmpty {
            // Cast `kCVPixelFormatType_32BGRA` (a `UInt32` / `OSType`) to `Int`
            // so it bridges correctly to `NSNumber` inside the settings
            // dictionary (Gemini review).
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
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
            // Decode the source audio to linear PCM so the writer's
            // (potentially compressed) input gets samples it can re-encode.
            // Passing `audioSettings: nil` would hand the writer the source's
            // native compressed samples and the append would fail (codex review).
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: preset.audioConfig.sampleRate,
                    AVNumberOfChannelsKey: preset.audioConfig.channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
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

        let sink = offlineMeterSink
        let cleanup = built.audioCleanup.requiresOfflineProcessing ? built.audioCleanup : nil
        if let audioOutput = readerAudioOutput {
            await Self.pump(input: audioInput, from: audioOutput,
                            totalDuration: totalDuration, progress: nil, meter: sink,
                            voiceCleanup: cleanup)
        } else if canAddAudio {
            audioInput.markAsFinished()
        }

        // A reader that failed mid-pump leaves the writer with a truncated
        // stream. Surface the read error instead of letting `finishWriting`
        // complete a silently-broken file (Gemini review).
        if reader.status == .failed, let error = reader.error {
            writer.cancelWriting()
            throw error
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

    /// Shared serial queue used by every pump invocation — there's at most
    /// one writer per job and pumps are sequential, so a single global queue
    /// is enough and avoids the per-pump allocation (Claude review).
    private nonisolated static let pumpQueue = DispatchQueue(
        label: "com.shenghaoc.LocalCutStudio.renderqueue.pump")

    /// Pulls one input dry. The progress callback is `@Sendable` because it's
    /// invoked on the writer's serial dispatch queue, not the MainActor.
    private nonisolated static func pump(
        input: AVAssetWriterInput,
        from output: AVAssetReaderOutput,
        totalDuration: Double,
        progress: (@Sendable (Double) -> Void)?,
        meter: (@Sendable (AudioMeterSnapshot) -> Void)? = nil,
        voiceCleanup: VoiceCleanupSettings? = nil
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = ResumeBox()
            let voiceCleanupState = VoiceCleanupStateBox()
            // `requestMediaDataWhenReady`'s block is `@Sendable`, but the writer
            // input and reader output it touches aren't `Sendable`. They're safe
            // here because the block only ever runs on the single serial
            // `pumpQueue` and this pump has sole ownership of both for its
            // lifetime — `nonisolated(unsafe)` states exactly that confinement.
            nonisolated(unsafe) let input = input
            nonisolated(unsafe) let output = output
            input.requestMediaDataWhenReady(on: pumpQueue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        let outputSample: CMSampleBuffer
                        if let voiceCleanup,
                           let processed = VoiceCleanupAudioProcessing.process(
                            sample: sample,
                            settings: voiceCleanup,
                            state: &voiceCleanupState.state) {
                            outputSample = processed
                        } else {
                            outputSample = sample
                        }

                        input.append(outputSample)
                        if let meter, let snapshot = audioMeterSnapshot(from: outputSample) {
                            meter(snapshot)
                        }
                        if let progress, totalDuration > 0 {
                            // Guard against non-numeric / invalid PTS so a bad
                            // sample doesn't propagate NaN into the UI
                            // (Gemini review).
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                            if pts.isValid && pts.isNumeric {
                                let fraction = Swift.max(0, Swift.min(1, pts.seconds / totalDuration))
                                if fraction.isFinite {
                                    progress(fraction)
                                }
                            }
                        }
                    } else {
                        // `markAsFinished()` signals the writer that no
                        // more samples will arrive. AVFoundation documents
                        // that the request block is no longer invoked once
                        // the input is finished. `ResumeBox` covers any
                        // in-flight invocation that might race past this
                        // point.
                        //
                        // Note: `stopRequestingMediaData()` does NOT exist
                        // on `AVAssetWriterInput` — only on
                        // `AVAssetReaderOutput` subclasses. The previous
                        // comment claiming otherwise was incorrect
                        // (confirmed by build: AVAssetWriterInput has no
                        // such member).
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

    nonisolated static func audioMeterSnapshot(from sample: CMSampleBuffer) -> AudioMeterSnapshot? {
        let frameCount = CMSampleBufferGetNumSamples(sample)
        guard frameCount > 0,
              let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }

        guard let channels = int16PCMChannelCount(for: sample) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        let byteCount = min(totalLength, frameCount * channels * MemoryLayout<Int16>.size)
        guard byteCount >= MemoryLayout<Int16>.size else { return nil }

        var lengthAtOffset = 0
        var contiguousTotalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &contiguousTotalLength,
            dataPointerOut: &dataPointer)
        if status == noErr, let dataPointer, lengthAtOffset >= byteCount {
            let bytes = UnsafeRawBufferPointer(start: dataPointer, count: byteCount)
            return audioMeterSnapshot(rawPCMBytes: bytes, channels: channels)
        }

        var copied = Data(count: byteCount)
        let copyStatus = copied.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination)
        }
        guard copyStatus == noErr else { return nil }
        return copied.withUnsafeBytes { bytes in
            audioMeterSnapshot(rawPCMBytes: bytes, channels: channels)
        }
    }

    private nonisolated static func audioMeterSnapshot(rawPCMBytes bytes: UnsafeRawBufferPointer,
                                                       channels: Int) -> AudioMeterSnapshot? {
        let sampleCount = bytes.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }
        var peak = Array(repeating: Float(0), count: min(2, channels))
        var sumSquares = Array(repeating: Float(0), count: min(2, channels))
        var counts = Array(repeating: 0, count: min(2, channels))

        for index in 0..<sampleCount {
            let channel = index % channels
            guard channel < 2 else { continue }
            let byteOffset = index * MemoryLayout<Int16>.size
            let bits = UInt16(bytes[byteOffset])
                | (UInt16(bytes[byteOffset + 1]) << 8)
            let value = max(-1, Float(Int16(bitPattern: bits)) / 32768)
            let magnitude = abs(value)
            peak[channel] = max(peak[channel], magnitude)
            sumSquares[channel] += value * value
            counts[channel] += 1
        }

        if channels == 1, peak.count == 1 {
            return AudioMeterSnapshot(
                peakLeft: peak[0], peakRight: peak[0],
                rmsLeft: counts[0] > 0 ? sqrt(sumSquares[0] / Float(counts[0])) : 0,
                rmsRight: counts[0] > 0 ? sqrt(sumSquares[0] / Float(counts[0])) : 0,
                sampledAt: ContinuousClock.now)
        }

        let leftRMS = counts[0] > 0 ? sqrt(sumSquares[0] / Float(counts[0])) : 0
        let rightRMS = counts.count > 1 && counts[1] > 0
            ? sqrt(sumSquares[1] / Float(counts[1]))
            : leftRMS
        let rightPeak = peak.count > 1 ? peak[1] : peak[0]
        return AudioMeterSnapshot(
            peakLeft: peak[0], peakRight: rightPeak,
            rmsLeft: leftRMS, rmsRight: rightRMS,
            sampledAt: ContinuousClock.now)
    }

    private nonisolated static func int16PCMChannelCount(for sample: CMSampleBuffer) -> Int? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let description = asbd.pointee
        let flags = description.mFormatFlags
        guard description.mFormatID == kAudioFormatLinearPCM,
              description.mBitsPerChannel == 16,
              description.mChannelsPerFrame > 0,
              description.mBytesPerFrame == description.mChannelsPerFrame * UInt32(MemoryLayout<Int16>.size),
              flags & kAudioFormatFlagIsSignedInteger != 0,
              flags & kAudioFormatFlagIsFloat == 0,
              flags & kAudioFormatFlagIsBigEndian == 0,
              flags & kAudioFormatFlagIsNonInterleaved == 0 else {
            return nil
        }
        return Int(description.mChannelsPerFrame)
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
    /// transition; the encode happens on the MainActor (where `jobs` lives)
    /// but the actual file write is hopped to a background queue so a slow
    /// disk can't stall the UI (Gemini review).
    private func persist() {
        guard persistsToDisk, !refusingPersist, let url = Self.queueFileURL() else { return }
        let doc = RenderQueueDoc(jobs: jobs)
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoded = try encoder.encode(doc)
        } catch {
            logger.error("queue persist failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let log = logger
        DispatchQueue.global(qos: .utility).async {
            do {
                try encoded.write(to: url, options: .atomic)
            } catch {
                log.error("queue persist failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reads the on-disk queue and reconciles state. Called once at app
    /// launch from the editor model. The file read happens off the MainActor
    /// so `EditorModel.init()` doesn't block the main thread on disk I/O at
    /// launch (Claude review); decoding then runs on the MainActor because
    /// `RenderQueueDoc.init(from:)` is implicitly MainActor-isolated under
    /// this target's default-isolation setting.
    func load() {
        guard let url = Self.queueFileURL() else { return }
        let log = logger
        Task.detached(priority: .userInitiated) { [weak self] in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                log.error("queue load failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            await self?.decodeAndApplyLoadedQueue(data: data)
        }
    }

    /// MainActor entry that decodes the queue document (Codable conformance
    /// on `RenderQueueDoc` is MainActor-isolated, so the decode must run
    /// here) and applies the reconciled state.
    private func decodeAndApplyLoadedQueue(data: Data) {
        let doc: RenderQueueDoc
        do {
            doc = try JSONDecoder().decode(RenderQueueDoc.self, from: data)
        } catch {
            logger.error("queue decode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        applyLoadedQueue(doc: doc)
    }

    /// MainActor entry that absorbs a decoded queue document. Split out so
    /// the file I/O can run off-thread and only the observable state
    /// mutation (`jobs`, `statusMessage`) + runner kick-off happens here.
    private func applyLoadedQueue(doc: RenderQueueDoc) {
        // A queue file written by a newer build carries fields we don't
        // understand. Latch `refusingPersist` so subsequent enqueue / cancel
        // calls don't overwrite the future-version file with the current
        // schema and drop the unknown payload (R3.6, codex P1).
        guard doc.version <= RenderQueueDoc.currentVersion else {
            refusingPersist = true
            statusMessage = "Render queue saved by a newer version — pausing persistence until update."
            return
        }
        let reconciled = Self.reconcile(loaded: doc.jobs)
        let didMutate = reconciled != doc.jobs
        jobs = reconciled
        recomputeTotalProgress()
        log("queue loaded — \(jobs.count) job(s)")
        // If reconciliation actually changed anything (a running → queued
        // rewind or a stale-bookmark → failed flip), persist so the change
        // survives a relaunch — otherwise the same stale state would be
        // re-resurrected on every launch (codex P2).
        if didMutate { persist() }
        // Resume the runner if any survived as queued.
        start()
    }

    /// Implements R3.2 + R3.3: any `running` job rewinds to `queued`; any job
    /// with a now-unresolvable `outputBookmark` flips to `failed`. A stale but
    /// resolvable output bookmark is refreshed in-place so the persisted queue
    /// does not keep resurrecting stale security-scope data.
    static func reconcile(
        loaded: [QueueJob],
        resolver: (Data) -> BookmarkResolution? = resolveSecurityScopedBookmark
    ) -> [QueueJob] {
        loaded.map { job in
            var copy = job
            if copy.status == .running {
                copy.status = .queued
                copy.progress = 0
                copy.errorMessage = nil
            }
            if copy.status == .queued {
                if let resolution = resolver(copy.outputBookmark) {
                    if let refreshed = resolution.refreshedBookmark {
                        copy.outputBookmark = refreshed
                    }
                } else {
                    copy.status = .failed
                    copy.errorMessage = RenderQueueError.outputDestinationUnavailable.localizedDescription
                }
            }
            return copy
        }
    }

    private nonisolated static func resolveSecurityScopedBookmark(_ bookmark: Data) -> BookmarkResolution? {
        guard !bookmark.isEmpty else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        let refreshed = stale ? refreshBookmark(for: url) : nil
        return BookmarkResolution(url: url, refreshedBookmark: refreshed)
    }

    private nonisolated static func refreshBookmark(for url: URL) -> Data? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: .withSecurityScope,
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
    }

    // MARK: Helpers

    /// Pre-resolved bookmark result. The URL is resolved off MainActor;
    // `startAccessing` and `MediaItem` assembly stay on MainActor.
    private struct ResolvedSource: Sendable {
        let refID: UUID
        let url: URL?
        let refreshedBookmark: Data?
    }

    /// Resolves every non-empty source-media bookmark to a URL on a background
    /// thread so sleeping drives or network shares don't stall the UI
    /// (Claude review). Pure function — no MainActor access.
    private nonisolated static func resolveSourceBookmarks(
        from media: [MediaRef]
    ) -> [ResolvedSource] {
        media.map { ref in
            guard !ref.bookmark.isEmpty else {
                return ResolvedSource(refID: ref.id, url: nil, refreshedBookmark: nil)
            }
            var stale = false
            let url = try? URL(resolvingBookmarkData: ref.bookmark,
                               options: [.withSecurityScope],
                               relativeTo: nil,
                               bookmarkDataIsStale: &stale)
            let refreshed: Data?
            if stale, let url {
                refreshed = refreshBookmark(for: url)
            } else {
                refreshed = nil
            }
            return ResolvedSource(refID: ref.id, url: url, refreshedBookmark: refreshed)
        }
    }

    private nonisolated static func resolveOverlayBookmarks(
        from overlays: [OverlayClipDoc]
    ) -> [ResolvedSource] {
        overlays.map { overlay in
            guard !overlay.bookmark.isEmpty else {
                return ResolvedSource(refID: overlay.id, url: nil, refreshedBookmark: nil)
            }
            var stale = false
            let url = try? URL(resolvingBookmarkData: overlay.bookmark,
                               options: [.withSecurityScope],
                               relativeTo: nil,
                               bookmarkDataIsStale: &stale)
            let refreshed: Data?
            if stale, let url {
                refreshed = refreshBookmark(for: url)
            } else {
                refreshed = nil
            }
            return ResolvedSource(refID: overlay.id, url: url, refreshedBookmark: refreshed)
        }
    }

    private func resolveBookmark(_ data: Data) -> BookmarkResolution? {
        outputBookmarkResolver(data)
    }

    private func refreshOutputBookmark(jobID: UUID, bookmark: Data) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].outputBookmark = bookmark
        persist()
    }

    private func refreshSourceBookmarks(
        in snapshot: ProjectDocument,
        jobID: UUID,
        resolvedMedia: [ResolvedSource],
        resolvedOverlays: [ResolvedSource]
    ) -> ProjectDocument {
        var refreshedSnapshot = snapshot
        var refreshedByID: [UUID: Data] = [:]
        for source in resolvedMedia + resolvedOverlays {
            if let bookmark = source.refreshedBookmark {
                refreshedByID[source.refID] = bookmark
            }
        }
        guard !refreshedByID.isEmpty else { return snapshot }

        for index in refreshedSnapshot.media.indices {
            if let refreshed = refreshedByID[refreshedSnapshot.media[index].id] {
                refreshedSnapshot.media[index].bookmark = refreshed
            }
        }
        for index in refreshedSnapshot.overlays.indices {
            if let refreshed = refreshedByID[refreshedSnapshot.overlays[index].id] {
                refreshedSnapshot.overlays[index].bookmark = refreshed
            }
        }
        if let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[jobIndex].projectSnapshot = refreshedSnapshot
            persist()
        }
        return refreshedSnapshot
    }

    /// Builds a throwaway `Project` from a Codable snapshot so the queue can
    /// reuse `CompositionBuilder.build(project:)` without touching the
    /// editor's live project.
    ///
    /// Returns the project, the URLs for which the runner now holds
    /// security-scoped access (must be stopped at job end — R3.4), and the
    /// count of source bookmarks that didn't resolve (the caller fails the
    /// job so missing media is surfaced instead of silently dropped).
    ///
    /// `preset.targetSize`, `aspect`, and `frameRate` override the snapshot's
    /// render settings so a preset-driven render actually produces the
    /// advertised dimensions even if the project was authored at a different
    /// canvas size.
    ///
    /// `preResolved` carries URLs already resolved off MainActor by
    /// `resolveSourceBookmarks`; this method only calls
    /// `startAccessingSecurityScopedResource()` and assembles `MediaItem`s.
    private func reconstructProject(from doc: ProjectDocument,
                                    applying preset: ExportPreset,
                                    preResolvedMedia: [ResolvedSource],
                                    preResolvedOverlays: [ResolvedSource])
        -> (project: Project, accessedSources: [URL], missingBookmarks: Int) {
        let project = Project()
        project.name = doc.name
        project.renderSize = preset.targetSize.cgSize
        project.frameRate = preset.frameRate ?? doc.frameRate
        project.masterGain = doc.audioBus.masterGain
        project.trackInputs = doc.audioBus.trackInputs.map(\.trackInput)
        project.voiceCleanup = doc.audioBus.voiceCleanup

        // Index pre-resolved results by ref ID for O(1) lookup.
        var resolvedByID: [UUID: URL?] = [:]
        for r in preResolvedMedia { resolvedByID[r.refID] = r.url }
        var resolvedOverlayByID: [UUID: URL?] = [:]
        for r in preResolvedOverlays { resolvedOverlayByID[r.refID] = r.url }

        var rebuilt: [MediaItem] = []
        var accessed: [URL] = []
        var missing = 0
        for ref in doc.media {
            guard !ref.bookmark.isEmpty else { missing += 1; continue }
            guard let url = resolvedByID[ref.id] ?? nil else {
                missing += 1
                continue
            }
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            } else {
                missing += 1
                continue
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
            let runtime = Track(id: track.id, name: track.name.isEmpty ? "V1" : track.name, kind: .video)
            runtime.isMuted = track.isMuted
            runtime.clips = track.clips.map { $0.makeClip() }
            return runtime
        }
        project.audioTracks = doc.audioTracks.map { track in
            let runtime = Track(id: track.id, name: track.name.isEmpty ? "A1" : track.name, kind: .audio)
            runtime.isMuted = track.isMuted
            runtime.clips = track.clips.map { $0.makeClip() }
            return runtime
        }
        if project.videoTracks.isEmpty { project.videoTracks = [Track(name: "V1", kind: .video)] }
        if project.audioTracks.isEmpty { project.audioTracks = [Track(name: "A1", kind: .audio)] }

        project.captionTracks = doc.captionTracks.map { $0.makeTrack() }
        project.overlays = doc.overlays.map { $0.makeOverlayClip() }
        for overlay in doc.overlays {
            if let path = overlay.bundleRelativePath,
               ProjectBundleLayout.isSafeAssetRelativePath(path) {
                project.overlayBundlePaths[overlay.id] = path
            }
            guard !overlay.bookmark.isEmpty else {
                missing += 1
                continue
            }
            guard let url = resolvedOverlayByID[overlay.id] ?? nil else {
                missing += 1
                continue
            }
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
                project.overlayBookmarks[overlay.id] = overlay.bookmark
            } else {
                missing += 1
            }
        }
        return (project, accessed, missing)
    }

    private func registerOverlaySources(for project: Project) async -> UUID? {
        var sources: [UUID: any OverlayFrameSource] = [:]
        for overlay in project.overlays {
            guard let bookmark = project.overlayBookmarks[overlay.id], !bookmark.isEmpty else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  !stale else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let source = await OverlayFrameSourceFactory.makeSource(for: overlay, sourceURL: url) else {
                continue
            }
            sources[overlay.id] = source
        }
        return EffectCompositor.registerOverlaySources(sources)
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    // MARK: Convenience entry points

    /// Builds + enqueues a job for the toolbar's Export shortcut, then starts
    /// the runner. The toolbar handler picks the destination URL, captures
    /// a security-scoped bookmark, snapshots the project, and calls this.
    func enqueueWithDefaultPreset(outputURL: URL,
                                  project: Project,
                                  bookmark: Data,
                                  projectDocumentURL: URL? = nil) {
        let snapshot = ProjectDocument(project: project, queueBundleURL: projectDocumentURL)
        let job = QueueJob(
            preset: BuiltInExportPresets.defaultPreset,
            outputBookmark: bookmark,
            outputDisplayName: outputURL.lastPathComponent,
            projectSnapshot: snapshot)
        enqueue(job)
    }
}
