import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import LocalCutCore

// MARK: - Program session error

enum ProgramSessionError: Error, Sendable {
    /// Another program session is already running.
    case sessionAlreadyRunning
    /// Encoder budget exhausted before any encoder opens.
    case budgetExhausted(EncoderBudgetError)
    /// A capture source failed to start.
    case sourceStartFailed(sourceID: UUID, underlying: Error)
    /// The session was cancelled before completion.
    case cancelled
    /// No sources configured.
    case noSources
    /// No scenes configured.
    case noScenes
    /// Hotkey conflict detected.
    case hotkeyConflict([String])
}

// MARK: - Program session result

struct ProgramSessionResult: Sendable {
    let sessionID: UUID
    let sessionURL: URL
    let manifest: CaptureManifest
    let isoTrackURLs: [UUID: URL] // sourceID -> file URL
    let duration: CMTime
    let sceneSwitches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)]
}

// MARK: - ProgramSession actor

/// Orchestrates a live Program Mode session. Extends the Phase 41 session
/// model with per-source `LiveComposeTap`s and a `ProgramCompositor`.
///
/// Responsibilities:
/// - Acquire encoder leases up front
/// - Create per-source pipelines (reusing Phase 41 capture infrastructure)
/// - Attach one `LiveComposeTap` per source
/// - Manage `ProgramCompositor`
/// - Write `scene-doc` and `scene-switch` manifest records
/// - Enforce one program session at a time
/// - Stop and land results (ISO tracks + layout track data)
actor ProgramSession {

    /// Whether a session is currently running. One session at a time.
    private(set) var isRunning = false

    /// The encoder budget shared across the app.
    private let budget: EncoderBudget

    /// The root URL for recording sessions.
    private let rootURL: URL

    /// The current session's directory.
    private var sessionURL: URL?

    /// The manifest file writer.
    private var manifestWriter: CaptureManifestFileWriter?

    /// The manifest records accumulated during the session.
    private var manifestRecords: [CaptureManifestRecord] = []

    /// Per-source capture running sessions.
    private var runningSessions: [UUID: CaptureRunningSession] = [:]

    /// Per-source continuous writers.
    private var writers: [UUID: ContinuousCaptureWriter] = [:]

    /// Per-source live compose taps.
    private var taps: [UUID: LiveComposeTap] = [:]

    /// Per-source encoder leases.
    private var leases: [EncoderLease] = []

    /// The program compositor.
    private var compositor: ProgramCompositor?

    /// The current scene document (snapshot at session start or last edit).
    private var currentSceneDoc: SceneDoc?

    /// The session ID.
    private var sessionID: UUID?

    /// Session start host time in microseconds.
    private var sessionStartHostTimeUs: Int64 = 0

    /// The scenes active at session start.
    private var startScenes: [SceneDefinition] = []

    init(budget: EncoderBudget, rootURL: URL) {
        self.budget = budget
        self.rootURL = rootURL
    }

    // MARK: - Start

    /// Starts a new program session. Fails if a session is already running.
    ///
    /// - Parameters:
    ///   - sources: Capture source descriptors (from the capture catalog).
    ///   - scenes: The scene definitions to use.
    ///   - renderSize: The output canvas size.
    ///   - onFrame: Called when a new composited frame is available.
    func start(sources: [CaptureSourceDescriptor],
               scenes: [SceneDefinition],
               renderSize: CGSize,
               onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
        guard !isRunning else {
            throw ProgramSessionError.sessionAlreadyRunning
        }
        guard !sources.isEmpty else {
            throw ProgramSessionError.noSources
        }
        guard !scenes.isEmpty else {
            throw ProgramSessionError.noScenes
        }
        let conflicts = detectHotkeyConflicts(in: scenes)
        guard conflicts.isEmpty else {
            throw ProgramSessionError.hotkeyConflict(conflicts)
        }

        // Acquire encoder leases up front. One per video source.
        let videoSources = sources.filter { $0.kind.isVideo }
        do {
            leases = try budget.acquire(.programIso, count: videoSources.count)
        } catch let error as EncoderBudgetError {
            throw ProgramSessionError.budgetExhausted(error)
        }

        // Set up session directory.
        let sid = UUID()
        sessionID = sid
        let dir = rootURL.appendingPathComponent(sid.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionURL = dir

        // Open manifest writer.
        let manifestURL = dir.appendingPathComponent("manifest.ndjson")
        manifestWriter = CaptureManifestFileWriter(url: manifestURL)

        // Record session start time.
        sessionStartHostTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))

        // Build encoder configs.
        var encoderConfigs: [UUID: CaptureEncoderConfig] = [:]
        for source in sources where source.kind.isVideo {
            let pixels = (source.width ?? 1920) * (source.height ?? 1080)
            let fps = source.frameRate ?? 30
            let bitrate = min(80_000_000, max(4_000_000, Int(Double(pixels) * fps * 0.08)))
            encoderConfigs[source.id] = CaptureEncoderConfig(
                codec: "h264",
                bitrate: bitrate,
                fragmentIntervalUs: 2_000_000)
        }

        // Write header.
        let header = CaptureManifestHeader(
            sessionID: sid,
            createdAt: Date(),
            sessionStartHostTimeUs: sessionStartHostTimeUs,
            sources: sources,
            encoders: encoderConfigs)
        appendRecord(.header(header))

        // Write epoch.
        let epoch = CaptureEpochRecord(
            atUs: sessionStartHostTimeUs,
            wallClock: Date())
        appendRecord(.epoch(epoch))

        // Write initial scene-doc.
        let sceneDoc = SceneDoc(scenes: scenes)
        currentSceneDoc = sceneDoc
        startScenes = scenes
        appendRecord(.sceneDoc(CaptureSceneDocRecord(
            atUs: sessionStartHostTimeUs,
            scenes: sceneDoc)))

        // Create compositor.
        compositor = ProgramCompositor(renderSize: renderSize)
        compositor?.updateScenes(scenes)

        // Create taps and writers for each source.
        for source in sources {
            let tap = LiveComposeTap(sourceID: source.id) { [weak self] in
                Task { await self?.tapDidDispose(sourceID: source.id) }
            }
            taps[source.id] = tap

            if source.kind.isVideo {
                // Create a writer for this source.
                let fileURL = dir.appendingPathComponent(source.relativePath)
                let writer = ContinuousCaptureWriter(
                    sourceID: source.id,
                    fileURL: fileURL,
                    mediaType: .video,
                    outputSettings: videoOutputSettings(for: source),
                    fragmentInterval: CMTime(value: 2, timescale: 1))
                writers[source.id] = writer
            }
        }

        isRunning = true
    }

    // MARK: - Scene switch

    /// Switches to a new scene. Writes a `scene-switch` manifest record.
    func switchScene(to sceneId: UUID, enableTransitions: Bool = false) {
        guard isRunning else { return }
        let atUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        appendRecord(.sceneSwitch(CaptureSceneSwitchRecord(sceneId: sceneId, atUs: atUs)))
        compositor?.switchScene(to: sceneId, enableTransitions: enableTransitions)
    }

    /// Updates scenes mid-session (e.g. user edited a scene). Writes a
    /// new `scene-doc` manifest record so recovery has the exact snapshot.
    func updateScenes(_ scenes: [SceneDefinition]) {
        guard isRunning else { return }
        let atUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let sceneDoc = SceneDoc(scenes: scenes)
        currentSceneDoc = sceneDoc
        appendRecord(.sceneDoc(CaptureSceneDocRecord(atUs: atUs, scenes: sceneDoc)))
        compositor?.updateScenes(scenes)
    }

    // MARK: - Feed frames

    /// Feeds a captured frame to the compositor via the source's tap.
    func feedFrame(sourceID: UUID, buffer: CVPixelBuffer) {
        taps[sourceID]?.feed(buffer)
        compositor?.updateSource(sourceID, buffer: buffer)
    }

    // MARK: - Stop

    /// Stops the session, finishes all writers, and returns the result.
    /// ISO track URLs and scene-switch data are included for layout
    /// track landing.
    func stop() async throws -> ProgramSessionResult {
        guard isRunning else {
            throw ProgramSessionError.cancelled
        }

        guard let sid = sessionID, let dir = sessionURL else {
            throw ProgramSessionError.cancelled
        }

        let stopTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))

        // Dispose all taps (close exactly once).
        for tap in taps.values {
            tap.dispose()
        }

        // Finish all writers concurrently.
        var endedRecords: [UUID: CaptureSourceEndedRecord] = [:]
        await withTaskGroup(of: (UUID, CaptureSourceEndedRecord?).self) { group in
            for (sourceID, writer) in writers {
                group.addTask {
                    let record = await writer.finish(atUs: stopTimeUs)
                    return (sourceID, record)
                }
            }
            for await (sourceID, record) in group {
                if let record {
                    endedRecords[sourceID] = record
                }
            }
        }

        // Write source-ended records to manifest.
        for record in endedRecords.values.sorted(by: { $0.sourceID.uuidString < $1.sourceID.uuidString }) {
            appendRecord(.sourceEnded(record))
        }

        // Write finalize record.
        let durationUs = stopTimeUs - sessionStartHostTimeUs
        appendRecord(.finalize(CaptureFinalizeRecord(atUs: stopTimeUs, durationUs: durationUs)))

        // Close manifest.
        manifestWriter?.close()

        // Release encoder leases.
        budget.releaseAll(leases)

        // Build result.
        let manifest = CaptureManifest(records: manifestRecords)
        let isoURLs = writers.keys.reduce(into: [UUID: URL]()) { result, sourceID in
            result[sourceID] = dir.appendingPathComponent(
                sources.first(where: { $0.id == sourceID })?.relativePath ?? "\(sourceID).mov")
        }

        // Clean up state.
        isRunning = false
        runningSessions.removeAll()
        writers.removeAll()
        taps.removeAll()
        leases.removeAll()
        compositor = nil
        manifestRecords.removeAll()
        manifestWriter = nil
        sessionURL = nil
        sessionID = nil

        return ProgramSessionResult(
            sessionID: sid,
            sessionURL: dir,
            manifest: manifest,
            isoTrackURLs: isoURLs,
            duration: CaptureManifest.time(fromMicroseconds: durationUs),
            sceneSwitches: manifest.resolvedSceneSwitches)
    }

    // MARK: - Private

    /// The sources configured for this session (from the header).
    private var sources: [CaptureSourceDescriptor] {
        manifestRecords.compactMap {
            if case .header(let h) = $0 { h.sources } else { nil }
        }.first ?? []
    }

    /// Appends a record to both the in-memory list and the file writer.
    private func appendRecord(_ record: CaptureManifestRecord) {
        manifestRecords.append(record)
        manifestWriter?.append(record)
    }

    /// Called when a tap's deinit fires without an explicit dispose.
    private func tapDidDispose(sourceID: UUID) {
        // No-op — the tap was already cleaned up.
    }

    /// Video output settings for a capture source.
    private func videoOutputSettings(for source: CaptureSourceDescriptor) -> [String: Any] {
        let width = source.width ?? 1920
        let height = source.height ?? 1920
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
    }
}
