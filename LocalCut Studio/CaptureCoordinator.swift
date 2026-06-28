import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import LocalCutCore

actor CaptureCoordinator {
    private enum State {
        case idle
        case starting
        case recording
        case paused
        case stopping
    }

    private struct ActiveSession {
        var id: UUID
        var directoryURL: URL
        var manifestURL: URL
        var manifest: CaptureManifestFileWriter
        var sessions: [CaptureRunningSession]
        var writers: [ContinuousCaptureWriter]
        var startHostTimeUs: Int64
        /// Accumulated finished writers from previous chunks (pause/resume cycles).
        /// Each pause finishes the current chunk's writers; they are collected here
        /// so `stop()` can finalize everything.
        var allFinishedWriters: [ContinuousCaptureWriter] = []
        /// The original `CaptureStartRequest` so `resume()` can recreate writers.
        var startRequest: CaptureStartRequest?
        /// Callbacks for stream events, stored for resume().
        var onStreamStopped: (@Sendable (Error) -> Void)?
        var onBackpressure: (@Sendable (CaptureSourceDescriptor) -> Void)?
        /// Monotonically increasing chunk counter for unique file names.
        var chunkIndex: Int = 1
    }

    private var state: State = .idle
    private var activeSession: ActiveSession?

    func start(_ request: CaptureStartRequest,
               onStreamStopped: (@Sendable (Error) -> Void)? = nil,
               onBackpressure: (@Sendable (CaptureSourceDescriptor) -> Void)? = nil) async throws {
        guard state == .idle else { throw CaptureEngineError.alreadyRecording }
        state = .starting
        var didStartRecording = false
        defer {
            if !didStartRecording {
                state = .idle
            }
        }
        let sourceCount = (request.target.map { _ in 1 } ?? 0)
            + (request.includeSystemAudio ? 1 : 0)
            + (request.webcamDeviceID == nil ? 0 : 1)
            + (request.microphoneDeviceID == nil ? 0 : 1)
        guard sourceCount > 0 else { throw CaptureEngineError.noCaptureSources }

        let videoStreamCount = (request.target.map { _ in 1 } ?? 0)
            + (request.webcamDeviceID == nil ? 0 : 1)
        let capability = request.capabilities.tier(for: .simultaneousCaptureStreams(count: max(1, videoStreamCount)))
        guard capability.tier >= .accelerated else {
            throw CaptureEngineError.captureSessionFailed(capability.reason)
        }
        // Phase 41: one/two video streams need .accelerated, three or more need
        // .pro headroom (extra encoders / memory).
        if videoStreamCount >= 3, capability.tier < .pro {
            throw CaptureEngineError.captureSessionFailed(
                "Recording three or more video sources requires a Pro-tier Mac.")
        }

        // Per-source resolution / fps preflight: compute the total pixel rate and
        // validate it against the tier's budget so a 4K60 config on accelerated
        // tier is rejected before capture starts rather than dropping mid-record.
        var totalPixelRate: Double = 0
        if let target = request.target {
            let size = target.outputSize
            totalPixelRate += Double(size.width * size.height) * request.frameRate
        }
        if request.webcamDeviceID != nil {
            let camSize = Self.webcamDimensions(deviceID: request.webcamDeviceID!)
            totalPixelRate += Double(camSize.width * camSize.height) * request.frameRate
        }
        let budget = Self.maxPixelRate(for: capability.tier)
        let budgetFormatted = Int(budget / 1_000_000)
        if totalPixelRate > budget {
            throw CaptureEngineError.captureSessionFailed(
                "Total capture rate (\(Int(totalPixelRate / 1_000_000).formatted()) MPx/s) exceeds the \(capability.tier == .accelerated ? "Accelerated" : "Pro") tier budget of \(budgetFormatted) MPx/s. Lower resolution or frame rate, or reduce the number of video sources.")
        }

        try await Self.preflightPermissions(for: request)

        let id = UUID()
        let directoryURL = request.rootURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Preflight free space so a capture doesn't begin only to fail once
        // samples are already being written and the take is half-recorded.
        if let available = try? directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           available < Self.minimumFreeBytes {
            try? FileManager.default.removeItem(at: directoryURL)
            throw CaptureEngineError.captureSessionFailed(
                "Not enough free space on the recordings volume — free at least \(Self.minimumFreeBytes / 1_000_000_000) GB and try again.")
        }
        let manifestURL = directoryURL.appendingPathComponent("manifest.ndjson")
        let manifest = try CaptureManifestFileWriter(url: manifestURL)
        let startHostTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let fragment = request.fragmentInterval

        var descriptors: [CaptureSourceDescriptor] = []
        var encoders: [UUID: CaptureEncoderConfig] = [:]
        var writers: [ContinuousCaptureWriter] = []
        var sessions: [CaptureRunningSession] = []

        var screenVideoWriter: ContinuousCaptureWriter?
        var screenAudioWriter: ContinuousCaptureWriter?

        if let target = request.target {
            let size = target.outputSize
            let source = CaptureSourceDescriptor(
                kind: target.sourceKind,
                displayName: target.displayName,
                relativePath: "screen.mov",
                width: size.width,
                height: size.height,
                frameRate: request.frameRate)
            let settings = Self.videoSettings(
                width: size.width,
                height: size.height,
                bitrate: Self.videoBitrate(width: size.width, height: size.height, frameRate: request.frameRate))
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(source.relativePath),
                mediaType: .video,
                outputSettings: settings,
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest,
                onSustainedBackpressure: onBackpressure)
            descriptors.append(source)
            encoders[source.id] = CaptureEncoderConfig(
                codec: "h264",
                bitrate: Self.videoBitrate(width: size.width, height: size.height, frameRate: request.frameRate),
                fragmentIntervalUs: CaptureManifest.microseconds(from: fragment))
            writers.append(writer)
            screenVideoWriter = writer
        }

        if request.includeSystemAudio {
            let source = CaptureSourceDescriptor(
                kind: .systemAudio,
                displayName: "System Audio",
                relativePath: "system-audio.mov",
                sampleRate: 48_000,
                channels: 2)
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(source.relativePath),
                mediaType: .audio,
                outputSettings: Self.audioSettings(sampleRate: 48_000, channels: 2),
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest,
                onSustainedBackpressure: onBackpressure)
            descriptors.append(source)
            encoders[source.id] = CaptureEncoderConfig(
                codec: "aac",
                bitrate: 192_000,
                fragmentIntervalUs: CaptureManifest.microseconds(from: fragment))
            writers.append(writer)
            screenAudioWriter = writer
        }

        if let target = request.target {
            sessions.append(ScreenCaptureSession(
                target: target,
                frameRate: request.frameRate,
                videoWriter: screenVideoWriter,
                audioWriter: screenAudioWriter,
                onStop: onStreamStopped))
        }

        if let webcamDeviceID = request.webcamDeviceID {
            // Match the writer to the camera's native dimensions so frames are
            // not rescaled by the encoder; fall back to 720p if unavailable.
            let camSize = Self.webcamDimensions(deviceID: webcamDeviceID)
            let bitrate = Self.videoBitrate(width: camSize.width, height: camSize.height, frameRate: request.frameRate)
            let source = CaptureSourceDescriptor(
                kind: .webcam,
                displayName: "Webcam",
                relativePath: "webcam.mov",
                width: camSize.width,
                height: camSize.height,
                frameRate: request.frameRate)
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(source.relativePath),
                mediaType: .video,
                outputSettings: Self.videoSettings(
                    width: camSize.width,
                    height: camSize.height,
                    bitrate: bitrate),
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest,
                onSustainedBackpressure: onBackpressure)
            descriptors.append(source)
            encoders[source.id] = CaptureEncoderConfig(
                codec: "h264",
                bitrate: bitrate,
                fragmentIntervalUs: CaptureManifest.microseconds(from: fragment))
            writers.append(writer)
            sessions.append(AVCaptureSampleSession(deviceID: webcamDeviceID, mediaType: .video, writer: writer))
        }

        if let microphoneDeviceID = request.microphoneDeviceID {
            let source = CaptureSourceDescriptor(
                kind: .microphone,
                displayName: "Microphone",
                relativePath: "microphone.mov",
                sampleRate: 48_000,
                channels: 1)
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(source.relativePath),
                mediaType: .audio,
                outputSettings: Self.audioSettings(sampleRate: 48_000, channels: 1),
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest,
                onSustainedBackpressure: onBackpressure)
            descriptors.append(source)
            encoders[source.id] = CaptureEncoderConfig(
                codec: "aac",
                bitrate: 96_000,
                fragmentIntervalUs: CaptureManifest.microseconds(from: fragment))
            writers.append(writer)
            sessions.append(AVCaptureSampleSession(deviceID: microphoneDeviceID, mediaType: .audio, writer: writer))
        }

        try manifest.append(.header(CaptureManifestHeader(
            sessionID: id,
            createdAt: Date(),
            sessionStartHostTimeUs: startHostTimeUs,
            sources: descriptors,
            encoders: encoders)))
        try manifest.append(.epoch(CaptureEpochRecord(atUs: startHostTimeUs, wallClock: Date())))

        let active = ActiveSession(
            id: id,
            directoryURL: directoryURL,
            manifestURL: manifestURL,
            manifest: manifest,
            sessions: sessions,
            writers: writers,
            startHostTimeUs: startHostTimeUs,
            startRequest: request,
            onStreamStopped: onStreamStopped,
            onBackpressure: onBackpressure)
        activeSession = active

        do {
            for session in sessions {
                try await session.start()
            }
        } catch {
            for session in sessions {
                await session.stop()
            }
            for writer in writers {
                _ = try? await writer.finish()
            }
            manifest.close()
            // Clean up the session directory so a failed start (permission denied,
            // camera in use, etc.) doesn't appear as a crash-recovery candidate on
            // the next launch — no frames were ever captured, and recovery would
            // surface bogus zero-duration rows.
            try? FileManager.default.removeItem(at: directoryURL)
            activeSession = nil
            state = .idle
            throw error
        }
        state = .recording
        didStartRecording = true
    }

    func stop() async throws -> CaptureSessionResult {
        guard state == .recording || state == .paused, let active = activeSession else {
            throw CaptureEngineError.notRecording
        }
        state = .stopping
        activeSession = nil

        // Stop all running sessions (no-op if already paused).
        for session in active.sessions {
            await session.stop()
        }

        // Finish every writer even if one fails, so no FileHandle or fragmented
        // .mov is left open. Run writers concurrently — `AVAssetWriter.finishWriting`
        // performs async disk I/O and fragment flushing, and sequential execution
        // can noticeably delay stop responsiveness with multiple sources.
        //
        // Include both the current chunk's writers and any previously finished
        // writers from pause/resume cycles. Only the current chunk's writers need
        // finishing; the others are already done.
        let activeWriters = active.writers
        let finishedWriters = active.allFinishedWriters
        var finishErrors: [Error] = []
        var allEndedRecords: [CaptureSourceEndedRecord] = []

        await withTaskGroup(of: (UUID, Result<CaptureSourceEndedRecord, Error>).self) { group in
            for writer in activeWriters {
                let sourceID = writer.source.id
                group.addTask {
                    do {
                        let ended = try await writer.finish()
                        return (sourceID, .success(ended))
                    } catch {
                        return (sourceID, .failure(error))
                    }
                }
            }
            for await (_, result) in group {
                switch result {
                case .success(let ended):
                    allEndedRecords.append(ended)
                case .failure(let error):
                    finishErrors.append(error)
                }
            }
        }

        // Append all ended records (current chunk + previously finished chunks).
        for ended in allEndedRecords {
            try? active.manifest.append(.sourceEnded(ended))
        }
        // Only finalize a clean stop. If a writer failed, leave the manifest
        // unfinalized so the session is still re-offered by crash recovery on the
        // next launch — but always return a partial result here so the UI can
        // land the sources that did finish, rather than throwing them away.
        var manifestFinalized = false
        if finishErrors.isEmpty {
            let durationUs = max(
                0,
                CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock())) - active.startHostTimeUs)
            manifestFinalized = (try? active.manifest.append(.finalize(CaptureFinalizeRecord(
                atUs: active.startHostTimeUs + durationUs,
                durationUs: durationUs)))) != nil
        }
        active.manifest.close()
        state = .idle

        let data = try Data(contentsOf: active.manifestURL)
        let parsed = CaptureManifest.parseNDJSON(data)
        var result = CaptureSessionResult(
            id: active.id,
            directoryURL: active.directoryURL,
            manifestURL: active.manifestURL,
            manifest: parsed,
            wasRecovered: false)
        if !manifestFinalized {
            result._manifestFinalizeFailed = true
        }
        return result
    }

    /// Pause the current recording. Stops all streams and finishes the current
    /// writer chunks. The PTS gap between pause and the subsequent `resume()` is
    /// preserved as a timestamp jump — the timeline shows the gap, not a stitched
    /// continuous clip.
    func pause() async throws {
        guard state == .recording, var active = activeSession else {
            throw CaptureEngineError.notRecording
        }
        state = .paused

        // Stop all capture streams.
        for session in active.sessions {
            await session.stop()
        }

        // Finish the current chunk's writers and collect ended records.
        let chunkWriters = active.writers
        await withTaskGroup(of: (UUID, Result<CaptureSourceEndedRecord, Error>).self) { group in
            for writer in chunkWriters {
                let sourceID = writer.source.id
                group.addTask {
                    do {
                        let ended = try await writer.finish()
                        return (sourceID, .success(ended))
                    } catch {
                        return (sourceID, .failure(error))
                    }
                }
            }
            for await (_, result) in group {
                switch result {
                case .success(let ended):
                    try? active.manifest.append(.sourceEnded(ended))
                case .failure:
                    break
                }
            }
        }

        // Record the pause event and accumulate finished writers.
        let pauseHostTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        try? active.manifest.append(.pause(CapturePauseRecord(atUs: pauseHostTimeUs)))
        active.allFinishedWriters.append(contentsOf: chunkWriters)
        active.writers = []
        active.sessions = []
        activeSession = active
    }

    /// Resume a paused recording. Creates new writer chunks for each source and
    /// restarts capture streams. The PTS gap since `pause()` is preserved.
    func resume() async throws {
        guard state == .paused, let active = activeSession, let request = active.startRequest else {
            throw CaptureEngineError.captureSessionFailed("No paused recording to resume.")
        }
        state = .starting
        var didStartRecording = false
        defer {
            if !didStartRecording { state = .paused }
        }

        let directoryURL = active.directoryURL
        let manifest = active.manifest
        let startHostTimeUs = active.startHostTimeUs
        let fragment = request.fragmentInterval
        let chunkIndex = active.chunkIndex
        var newChunkIndex = chunkIndex

        var writers: [ContinuousCaptureWriter] = []
        var sessions: [CaptureRunningSession] = []
        var screenVideoWriter: ContinuousCaptureWriter?
        var screenAudioWriter: ContinuousCaptureWriter?

        // Create new writer chunks with unique file names.
        if let target = request.target {
            let size = target.outputSize
            let filename = "screen-\(chunkIndex).mov"
            let source = CaptureSourceDescriptor(
                kind: target.sourceKind,
                displayName: target.displayName,
                relativePath: filename,
                width: size.width,
                height: size.height,
                frameRate: request.frameRate)
            let settings = Self.videoSettings(
                width: size.width,
                height: size.height,
                bitrate: Self.videoBitrate(width: size.width, height: size.height, frameRate: request.frameRate))
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(filename),
                mediaType: .video,
                outputSettings: settings,
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest)
            writers.append(writer)
            screenVideoWriter = writer
            newChunkIndex += 1
        }

        if request.includeSystemAudio {
            let filename = "system-audio-\(chunkIndex).mov"
            let source = CaptureSourceDescriptor(
                kind: .systemAudio,
                displayName: "System Audio",
                relativePath: filename,
                sampleRate: 48_000,
                channels: 2)
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(filename),
                mediaType: .audio,
                outputSettings: Self.audioSettings(sampleRate: 48_000, channels: 2),
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest)
            writers.append(writer)
            screenAudioWriter = writer
            newChunkIndex += 1
        }

        if let target = request.target {
            sessions.append(ScreenCaptureSession(
                target: target,
                frameRate: request.frameRate,
                videoWriter: screenVideoWriter,
                audioWriter: screenAudioWriter,
                onStop: active.onStreamStopped))
        }

        if let webcamDeviceID = request.webcamDeviceID {
            let camSize = Self.webcamDimensions(deviceID: webcamDeviceID)
            let bitrate = Self.videoBitrate(width: camSize.width, height: camSize.height, frameRate: request.frameRate)
            let filename = "webcam-\(chunkIndex).mov"
            let source = CaptureSourceDescriptor(
                kind: .webcam,
                displayName: "Webcam",
                relativePath: filename,
                width: camSize.width,
                height: camSize.height,
                frameRate: request.frameRate)
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(filename),
                mediaType: .video,
                outputSettings: Self.videoSettings(
                    width: camSize.width,
                    height: camSize.height,
                    bitrate: bitrate),
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest)
            writers.append(writer)
            sessions.append(AVCaptureSampleSession(deviceID: webcamDeviceID, mediaType: .video, writer: writer))
            newChunkIndex += 1
        }

        if let microphoneDeviceID = request.microphoneDeviceID {
            let filename = "microphone-\(chunkIndex).mov"
            let source = CaptureSourceDescriptor(
                kind: .microphone,
                displayName: "Microphone",
                relativePath: filename,
                sampleRate: 48_000,
                channels: 1)
            let writer = try ContinuousCaptureWriter(
                source: source,
                outputURL: directoryURL.appendingPathComponent(filename),
                mediaType: .audio,
                outputSettings: Self.audioSettings(sampleRate: 48_000, channels: 1),
                fragmentInterval: fragment,
                sessionStartHostTimeUs: startHostTimeUs,
                manifest: manifest)
            writers.append(writer)
            sessions.append(AVCaptureSampleSession(deviceID: microphoneDeviceID, mediaType: .audio, writer: writer))
            newChunkIndex += 1
        }

        // Record resume event.
        let resumeHostTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        try? manifest.append(.resume(CaptureResumeRecord(atUs: resumeHostTimeUs)))

        // Update the active session with new writers and sessions.
        var updated = active
        updated.writers = writers
        updated.sessions = sessions
        updated.chunkIndex = newChunkIndex
        activeSession = updated

        do {
            for session in sessions {
                try await session.start()
            }
        } catch {
            for writer in writers {
                _ = try? await writer.finish()
            }
            // Restore paused state so user can retry or stop.
            var restored = updated
            restored.writers = []
            restored.sessions = []
            activeSession = restored
            state = .paused
            throw error
        }
        state = .recording
        didStartRecording = true
    }

    /// Switch the capture source mid-session. Updates the screen capture
    /// session's target (content filter + configuration). The first frame after
    /// the switch is dropped to avoid transitional artifacts.
    func updateSource(_ newTarget: CaptureTarget) async throws {
        guard state == .recording, let active = activeSession else {
            throw CaptureEngineError.notRecording
        }
        // Find the ScreenCaptureSession and update it.
        for session in active.sessions {
            if let screenSession = session as? ScreenCaptureSession {
                try await screenSession.updateTarget(newTarget)
                return
            }
        }
        throw CaptureEngineError.captureSessionFailed("No screen capture session to update.")
    }

    /// The CGWindowID of the floating control panel, used to exclude it from
    /// screen capture. Set by the EditorModel when the panel is shown.
    private var floatingPanelWindowID: CGWindowID = 0

    /// Update the floating panel window ID for capture exclusion.
    func setFloatingPanelWindowID(_ windowID: CGWindowID) {
        floatingPanelWindowID = windowID
    }

    func scanRecoveredSessions(rootURL: URL) throws -> [CaptureSessionResult] {
        // A live recording's manifest isn't finalized yet; don't mistake it for
        // a crashed session.
        let activeID = state == .idle ? nil : activeSession?.id
        let contents = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        return contents.compactMap { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let manifestURL = directory.appendingPathComponent("manifest.ndjson")
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            let manifest = CaptureManifest.parseNDJSON(data)
            guard !manifest.isFinalized, manifest.header != nil else { return nil }
            if let activeID, manifest.header?.sessionID == activeID { return nil }
            return CaptureSessionResult(
                id: manifest.header?.sessionID ?? UUID(),
                directoryURL: directory,
                manifestURL: manifestURL,
                manifest: manifest,
                wasRecovered: true)
        }
    }

    /// Refuse to start a capture when the recordings volume has less than this
    /// much important-usage space available.
    private static let minimumFreeBytes: Int64 = 2_000_000_000

    private static func preflightPermissions(for request: CaptureStartRequest) async throws {
        if request.target != nil, !CapturePermissionAuthorizer.requestScreenRecordingAccess() {
            throw CaptureEngineError.screenRecordingDenied
        }
        if request.webcamDeviceID != nil,
           !(await CapturePermissionAuthorizer.requestDeviceAccess(for: .video)) {
            throw CaptureEngineError.cameraPermissionDenied
        }
        if request.microphoneDeviceID != nil,
           !(await CapturePermissionAuthorizer.requestDeviceAccess(for: .audio)) {
            throw CaptureEngineError.microphonePermissionDenied
        }
    }

    /// Maximum combined pixel rate (width × height × fps) per tier. Accelerated
    /// tops out at 1080p30 (≈ 62 MPx/s); Pro allows 4K60 (≈ 498 MPx/s).
    /// Baseline returns 0 so any capture request is rejected.
    private static func maxPixelRate(for tier: CapabilityTier) -> Double {
        switch tier {
        case .baseline: return 0
        case .accelerated: return 1920 * 1080 * 30  // ~62 MPx/s
        case .pro: return 3840 * 2160 * 60  // ~498 MPx/s
        }
    }

    private static func webcamDimensions(deviceID: String) -> (width: Int, height: Int) {
        let fallback = (width: 1280, height: 720)
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { return fallback }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let width = Int(dims.width) & ~1
        let height = Int(dims.height) & ~1
        guard width >= 16, height >= 16 else { return fallback }
        return (width, height)
    }

    private static func videoBitrate(width: Int, height: Int, frameRate: Double) -> Int {
        let pixels = Double(max(1, width * height))
        let base = pixels * max(1, frameRate) * 0.08
        return max(4_000_000, min(80_000_000, Int(base)))
    }

    private static func videoSettings(width: Int, height: Int, bitrate: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                kVTCompressionPropertyKey_RealTime as String: true,
            ],
        ]
    }

    private static func audioSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 192_000 : 96_000,
        ]
    }
}
