import Foundation
import AVFoundation
import CoreMedia
@preconcurrency import CoreVideo
import LocalCutCore

// MARK: - Program session error

enum ProgramSessionError: Error, Sendable, Equatable, LocalizedError {
    /// Another program session is already running.
    case sessionAlreadyRunning
    /// Encoder budget exhausted before any encoder opens.
    case budgetExhausted(EncoderBudgetError)
    /// The session was cancelled before completion.
    case cancelled
    /// No sources configured.
    case noSources
    /// No scenes configured.
    case noScenes
    /// Hotkey conflict detected.
    case hotkeyConflict([String])
    /// One of the underlying capture sessions failed.
    case captureFailed(String)
    /// One or more ISO writers failed to finish cleanly.
    case writerFinishFailed([String])

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyRunning:
            "A program session is already running."
        case .budgetExhausted(let error):
            error.localizedDescription
        case .cancelled:
            "The program session was cancelled."
        case .noSources:
            "Select at least one program source."
        case .noScenes:
            "Create at least one program scene."
        case .hotkeyConflict(let conflicts):
            "Program scene hotkey conflict: \(conflicts.joined(separator: ", "))."
        case .captureFailed(let reason):
            "Program capture failed: \(reason)"
        case .writerFinishFailed(let failures):
            "Program recording could not finish: \(failures.joined(separator: "; "))"
        }
    }
}

// MARK: - Program session result

nonisolated enum ProgramCaptureEndpoint: Hashable, Sendable {
    case screen(CaptureTarget)
    case webcam(deviceID: String)
    case microphone(deviceID: String)
    case detached
}

nonisolated struct ProgramCaptureSource: Identifiable, Hashable, Sendable {
    var descriptor: CaptureSourceDescriptor
    var endpoint: ProgramCaptureEndpoint
    /// Whether this source is selected for the next Program Mode session.
    var isEnabled: Bool = true

    var id: UUID { descriptor.id }

    init(descriptor: CaptureSourceDescriptor, endpoint: ProgramCaptureEndpoint = .detached) {
        self.descriptor = descriptor
        self.endpoint = endpoint
    }
}

nonisolated struct ProgramFrameBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

struct ProgramSessionResult: Sendable {
    let sessionID: UUID
    let sessionURL: URL
    let manifest: CaptureManifest
    let isoTrackURLs: [UUID: URL] // sourceID -> file URL
    let duration: CMTime
    let sceneSwitches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)]
    /// Non-empty when one or more writers failed to finish cleanly.
    /// The UI should surface these as warnings while still landing
    /// the successfully recorded sources.
    let writerWarnings: [String]
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

    /// Whether a session is in the process of starting. Guards against
    /// reentrant `start()` calls during the async capture startup phase.
    private var isStarting = false

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

    /// Live program frame callback supplied by the caller.
    private var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

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

    /// Starts a descriptor-only program session for tests and recovery-style
    /// fixtures that inject frames manually through `feedFrame`.
    func start(sources: [CaptureSourceDescriptor],
               scenes: [SceneDefinition],
               renderSize: CGSize,
               onFrame: (@Sendable (CVPixelBuffer) -> Void)? = nil) async throws {
        try await start(
            captureSources: sources.map { ProgramCaptureSource(descriptor: $0) },
            scenes: scenes,
            renderSize: renderSize,
            onFrame: onFrame)
    }

    /// Starts a new program session. Fails if a session is already running.
    ///
    /// - Parameters:
    ///   - captureSources: Source descriptors plus their live capture binding.
    ///   - scenes: The scene definitions to use.
    ///   - renderSize: The output canvas size.
    ///   - onFrame: Called when a new composited frame is available.
    func start(captureSources: [ProgramCaptureSource],
               scenes: [SceneDefinition],
               renderSize: CGSize,
               onFrame: (@Sendable (CVPixelBuffer) -> Void)? = nil) async throws {
        guard !isRunning, !isStarting else {
            throw ProgramSessionError.sessionAlreadyRunning
        }
        isStarting = true
        let sources = captureSources.map(\.descriptor)
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
        self.onFrame = onFrame

        do {
            // Acquire encoder leases up front. One per video source.
            let videoSources = sources.filter { $0.kind.isVideo }
            leases = try await budget.acquire(.programIso, count: videoSources.count)
            let sid = UUID()
            sessionID = sid
            let dir = rootURL.appendingPathComponent(sid.uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            sessionURL = dir

            let manifestURL = dir.appendingPathComponent("manifest.ndjson")
            let manifest = try CaptureManifestFileWriter(url: manifestURL)
            manifestWriter = manifest

            sessionStartHostTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))

            var encoderConfigs: [UUID: CaptureEncoderConfig] = [:]
            for source in sources {
                if source.kind.isVideo {
                    let pixels = (source.width ?? 1920) * (source.height ?? 1080)
                    let fps = source.frameRate ?? 30
                    let bitrate = min(80_000_000, max(4_000_000, Int(Double(pixels) * fps * 0.08)))
                    encoderConfigs[source.id] = CaptureEncoderConfig(
                        codec: "h264",
                        bitrate: bitrate,
                        fragmentIntervalUs: 2_000_000)
                } else {
                    encoderConfigs[source.id] = CaptureEncoderConfig(
                        codec: "aac",
                        bitrate: source.kind == .microphone ? 96_000 : 192_000,
                        fragmentIntervalUs: 2_000_000)
                }
            }

            appendRecord(.header(CaptureManifestHeader(
                sessionID: sid,
                createdAt: Date(),
                sessionStartHostTimeUs: sessionStartHostTimeUs,
                sources: sources,
                encoders: encoderConfigs)))
            appendRecord(.epoch(CaptureEpochRecord(
                atUs: sessionStartHostTimeUs,
                wallClock: Date())))

            let sceneDoc = SceneDoc(scenes: scenes)
            currentSceneDoc = sceneDoc
            startScenes = scenes
            appendRecord(.sceneDoc(CaptureSceneDocRecord(
                atUs: sessionStartHostTimeUs,
                scenes: sceneDoc)))

            compositor = ProgramCompositor(renderSize: renderSize)
            compositor?.updateScenes(scenes)
            compositor?.switchScene(to: scenes[0].id)
            appendRecord(.sceneSwitch(CaptureSceneSwitchRecord(
                sceneId: scenes[0].id,
                atUs: sessionStartHostTimeUs)))

            for captureSource in captureSources {
                let source = captureSource.descriptor
                let tap = LiveComposeTap(sourceID: source.id)
                taps[source.id] = tap

                let writer: ContinuousCaptureWriter
                if source.kind.isVideo {
                    writer = try ContinuousCaptureWriter(
                        source: source,
                        outputURL: dir.appendingPathComponent(source.relativePath),
                        mediaType: .video,
                        outputSettings: videoOutputSettings(for: source),
                        fragmentInterval: CMTime(value: 2, timescale: 1),
                        sessionStartHostTimeUs: sessionStartHostTimeUs,
                        manifest: manifest)
                } else {
                    writer = try ContinuousCaptureWriter(
                        source: source,
                        outputURL: dir.appendingPathComponent(source.relativePath),
                        mediaType: .audio,
                        outputSettings: audioOutputSettings(for: source),
                        fragmentInterval: CMTime(value: 2, timescale: 1),
                        sessionStartHostTimeUs: sessionStartHostTimeUs,
                        manifest: manifest)
                }
                writers[source.id] = writer

                if let running = runningSession(for: captureSource, writer: writer) {
                    runningSessions[source.id] = running
                }
            }

            var startedSessions: [CaptureRunningSession] = []
            do {
                for session in runningSessions.values {
                    try await session.start()
                    startedSessions.append(session)
                }
            } catch {
                for session in startedSessions {
                    await session.stop()
                }
                throw ProgramSessionError.captureFailed(error.localizedDescription)
            }

            isStarting = false
            isRunning = true
        } catch let error as EncoderBudgetError {
            isStarting = false
            await cleanupFailedStart(removeDirectory: true)
            throw ProgramSessionError.budgetExhausted(error)
        } catch {
            isStarting = false
            await cleanupFailedStart(removeDirectory: true)
            throw error
        }
    }

    // MARK: - Scene switch

    /// Switches to a new scene. Writes a `scene-switch` manifest record.
    func switchScene(to sceneId: UUID, enableTransitions: Bool = false) async {
        guard isRunning else { return }
        let atUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        appendRecord(.sceneSwitch(CaptureSceneSwitchRecord(sceneId: sceneId, atUs: atUs)))
        compositor?.switchScene(to: sceneId, enableTransitions: enableTransitions)
    }

    /// Updates scenes mid-session (e.g. user edited a scene). Writes a
    /// new `scene-doc` manifest record so recovery has the exact snapshot.
    func updateScenes(_ scenes: [SceneDefinition]) async {
        guard isRunning else { return }
        let atUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let sceneDoc = SceneDoc(scenes: scenes)
        currentSceneDoc = sceneDoc
        appendRecord(.sceneDoc(CaptureSceneDocRecord(atUs: atUs, scenes: sceneDoc)))
        compositor?.updateScenes(scenes)
    }

    // MARK: - Feed frames

    /// Feeds a captured frame to the compositor via the source's tap.
    func feedFrame(sourceID: UUID, buffer: ProgramFrameBuffer) async {
        let pixelBuffer = buffer.pixelBuffer
        taps[sourceID]?.feed(pixelBuffer)
        compositor?.updateSource(sourceID, buffer: pixelBuffer)
        // Only render the composited frame when the caller needs it.
        // Rendering is expensive (full-resolution CoreImage/Metal composite).
        if onFrame != nil, let frame = compositor?.renderFrame() {
            onFrame?(frame)
        }
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

        // Stop live capture before closing taps/writers so no late samples race
        // with writer finalization.
        for session in runningSessions.values {
            await session.stop()
        }

        // Dispose all taps (close exactly once).
        for tap in taps.values {
            tap.dispose()
        }

        // Finish all writers concurrently.
        var endedRecords: [UUID: CaptureSourceEndedRecord] = [:]
        var finishFailures: [String] = []
        await withTaskGroup(of: (UUID, Result<CaptureSourceEndedRecord, Error>).self) { group in
            for (sourceID, writer) in writers {
                group.addTask {
                    do {
                        return (sourceID, .success(try await writer.finish()))
                    } catch {
                        return (sourceID, .failure(error))
                    }
                }
            }
            for await (sourceID, result) in group {
                switch result {
                case .success(let record):
                    endedRecords[sourceID] = record
                case .failure(let error):
                    finishFailures.append(error.localizedDescription)
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
        await budget.releaseAll(leases)

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
        currentSceneDoc = nil
        startScenes.removeAll()
        onFrame = nil

        // Return partial results even when some writers failed. The
        // successfully ended records are already persisted and the UI
        // can land the sources that finished cleanly.
        return ProgramSessionResult(
            sessionID: sid,
            sessionURL: dir,
            manifest: manifest,
            isoTrackURLs: isoURLs,
            duration: CaptureManifest.time(fromMicroseconds: durationUs),
            sceneSwitches: manifest.resolvedSceneSwitches,
            writerWarnings: finishFailures)
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
        do {
            try manifestWriter?.append(record)
        } catch {
            // Manifest write failure is non-fatal for the running session
            // (in-memory records are still available for landing), but
            // crash recovery will be incomplete. Log for diagnostics.
            NSLog("[ProgramSession] manifest append failed: \(error)")
        }
    }

    /// Called when a screen capture session stops with an error (e.g. window
    /// closed, permission revoked). Logs the error; the session continues
    /// running for remaining sources.
    private func handleCaptureStopError(sourceID: UUID, error: Error) {
        NSLog("[ProgramSession] capture stop error for source \(sourceID): \(error)")
    }

    private func runningSession(for captureSource: ProgramCaptureSource,
                                writer: ContinuousCaptureWriter) -> CaptureRunningSession? {
        let sourceID = captureSource.id
        let frameCallback: @Sendable (CVPixelBuffer) -> Void = { [weak self] buffer in
            let frameBuffer = ProgramFrameBuffer(buffer)
            Task { await self?.feedFrame(sourceID: sourceID, buffer: frameBuffer) }
        }

        switch captureSource.endpoint {
        case .screen(let target):
            return ScreenCaptureSession(
                target: target,
                frameRate: captureSource.descriptor.frameRate ?? 30,
                videoWriter: writer,
                audioWriter: nil,
                onStop: { [weak self] error in
                    Task { await self?.handleCaptureStopError(sourceID: sourceID, error: error) }
                },
                onVideoFrame: frameCallback)
        case .webcam(let deviceID):
            return AVCaptureSampleSession(
                deviceID: deviceID,
                mediaType: .video,
                writer: writer,
                onVideoFrame: frameCallback)
        case .microphone(let deviceID):
            return AVCaptureSampleSession(
                deviceID: deviceID,
                mediaType: .audio,
                writer: writer)
        case .detached:
            return nil
        }
    }

    private func cleanupFailedStart(removeDirectory: Bool) async {
        for session in runningSessions.values {
            await session.stop()
        }
        await withTaskGroup(of: Void.self) { group in
            for writer in writers.values {
                group.addTask {
                    _ = try? await writer.finish()
                }
            }
        }
        manifestWriter?.close()
        await budget.releaseAll(leases)
        if removeDirectory, let sessionURL {
            try? FileManager.default.removeItem(at: sessionURL)
        }

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
        currentSceneDoc = nil
        startScenes.removeAll()
        onFrame = nil
    }

    /// Video output settings for a capture source.
    private func videoOutputSettings(for source: CaptureSourceDescriptor) -> [String: Any] {
        let width = source.width ?? 1920
        let height = source.height ?? 1080
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
    }

    private func audioOutputSettings(for source: CaptureSourceDescriptor) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.sampleRate ?? 48_000,
            AVNumberOfChannelsKey: source.channels ?? 1,
            AVEncoderBitRateKey: source.kind == .microphone ? 96_000 : 192_000,
        ]
    }
}
