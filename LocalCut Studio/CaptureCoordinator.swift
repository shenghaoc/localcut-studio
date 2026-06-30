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
        case pausing
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
        /// The original `CaptureStartRequest` so `resume()` can recreate writers.
        var startRequest: CaptureStartRequest?
        /// Callbacks for stream events, stored for resume().
        var onStreamStopped: (@Sendable (Error) -> Void)?
        var onBackpressure: (@Sendable (CaptureSourceDescriptor) -> Void)?
        var onMicrophoneLevel: (@Sendable (Float) -> Void)?
        /// Monotonically increasing chunk counter for unique file names. Incremented
        /// once per resume cycle (not per source).
        var chunkIndex: Int = 1
        /// The current capture target, updated by `updateSource()`. Resume uses
        /// this instead of `startRequest.target` so switched targets are preserved.
        var currentTarget: CaptureTarget?
        /// Source IDs from the original header, reused for resumed chunks so
        /// `source-ended` records are keyed to header sources.
        var sourceIDs: [CaptureSourceKind: UUID] = [:]
        /// Once a critical manifest append fails, the session must remain
        /// unfinalized so recovery can inspect the fragmented files on next launch.
        var manifestWriteFailed = false
        /// Event log writer for screen/application/window targets. Own-app
        /// targets include key codes; non-own targets record mouse/scroll only.
        var eventLogWriter: ScreencastEventLogWriter?
    }

    private var state: State = .idle
    private var activeSession: ActiveSession?

    func start(_ request: CaptureStartRequest,
               onStreamStopped: (@Sendable (Error) -> Void)? = nil,
               onBackpressure: (@Sendable (CaptureSourceDescriptor) -> Void)? = nil,
               onMicrophoneLevel: (@Sendable (Float) -> Void)? = nil) async throws {
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
        let availableCapacity: Int64
        do {
            availableCapacity = try directoryURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw CaptureEngineError.captureSessionFailed(
                "Could not check free space on the recordings volume: \(error.localizedDescription)")
        }
        if availableCapacity < Self.minimumFreeBytes {
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
        let excludedWindowIDs = request.excludedWindowIDs.union(
            floatingPanelWindowID == 0 ? [] : [floatingPanelWindowID])

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
                captureRegion: request.captureRegion,
                excludingWindowIDs: excludedWindowIDs,
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
            sessions.append(AVCaptureSampleSession(
                deviceID: microphoneDeviceID,
                mediaType: .audio,
                writer: writer,
                onAudioLevel: onMicrophoneLevel))
        }

        try manifest.append(.header(CaptureManifestHeader(
            sessionID: id,
            createdAt: Date(),
            sessionStartHostTimeUs: startHostTimeUs,
            sources: descriptors,
            encoders: encoders)))
        try manifest.append(.epoch(CaptureEpochRecord(atUs: startHostTimeUs, wallClock: Date())))

        // Build source ID map so resumed chunks reuse the same IDs.
        var sourceIDs: [CaptureSourceKind: UUID] = [:]
        for descriptor in descriptors {
            sourceIDs[descriptor.kind] = descriptor.id
        }
        // Create an event log writer for screen targets. Webcam/mic-only
        // recordings have no screen coordinate space for proposals.
        var eventLogWriter: ScreencastEventLogWriter?
        if let target = request.target {
            eventLogWriter = ScreencastEventLogWriter(
                sessionID: id,
                startHostTimeUs: startHostTimeUs,
                directoryURL: directoryURL,
                target: target,
                captureRegion: request.captureRegion)
        }

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
            onBackpressure: onBackpressure,
            onMicrophoneLevel: onMicrophoneLevel,
            currentTarget: request.target,
            sourceIDs: sourceIDs,
            eventLogWriter: eventLogWriter)
        activeSession = active

        do {
            for session in sessions {
                try await session.start()
            }
        } catch {
            for session in sessions {
                await session.stop()
            }
            let cleanupErrors = await Self.finishWritersCollectingErrors(writers)
            manifest.close()
            // Clean up the session directory so a failed start (permission denied,
            // camera in use, etc.) doesn't appear as a crash-recovery candidate on
            // the next launch — no frames were ever captured, and recovery would
            // surface bogus zero-duration rows.
            try? FileManager.default.removeItem(at: directoryURL)
            activeSession = nil
            state = .idle
            if !cleanupErrors.isEmpty {
                throw CaptureEngineError.captureSessionFailed(
                    "\(error.localizedDescription); cleanup errors: \(cleanupErrors.joined(separator: "; "))")
            }
            throw error
        }
        // Start event monitoring after screen sessions are running so event
        // timestamps align with the capture clock.
        await activeSession?.eventLogWriter?.startMonitoring()
        state = .recording
        didStartRecording = true
    }

    func stop() async throws -> CaptureSessionResult {
        guard state == .recording || state == .paused, let active = activeSession else {
            throw CaptureEngineError.notRecording
        }
        state = .stopping
        activeSession = nil

        // Stop event monitoring and flush the event log sidecar.
        await active.eventLogWriter?.stopMonitoring()
        var eventLogFlushError: String?
        do {
            if let writer = active.eventLogWriter {
                let snapshot = await writer.snapshotEvents()
                try writer.flush(events: snapshot)
            }
        } catch {
            eventLogFlushError = "Event log: \(error.localizedDescription)"
        }

        // Stop all running sessions (no-op if already paused).
        for session in active.sessions {
            await session.stop()
        }

        // Finish every writer even if one fails, so no FileHandle or fragmented
        // .mov is left open. Run writers concurrently — `AVAssetWriter.finishWriting`
        // performs async disk I/O and fragment flushing, and sequential execution
        // can noticeably delay stop responsiveness with multiple sources.
        //
        // Only the current chunk's writers need finishing; previously finished
        // writers from pause/resume cycles already have their sourceEnded records
        // appended to the manifest during pause().
        let activeWriters = active.writers
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

        // Only finalize a clean stop. If a writer failed or a source-ended record
        // cannot be persisted, leave the manifest
        // unfinalized so the session is still re-offered by crash recovery on the
        // next launch — but always return a partial result here so the UI can
        // land the sources that did finish, rather than throwing them away.
        var manifestErrors: [Error] = []
        for ended in allEndedRecords {
            do {
                try active.manifest.append(.sourceEnded(ended))
            } catch {
                manifestErrors.append(error)
            }
        }
        finishErrors.append(contentsOf: manifestErrors)

        var manifestFinalized = false
        var manifestFinalizationError: String?
        if finishErrors.isEmpty, !active.manifestWriteFailed {
            let durationUs = max(
                0,
                CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock())) - active.startHostTimeUs)
            do {
                try active.manifest.append(.finalize(CaptureFinalizeRecord(
                    atUs: active.startHostTimeUs + durationUs,
                    durationUs: durationUs)))
                manifestFinalized = true
            } catch {
                manifestFinalizationError = error.localizedDescription
            }
        } else if active.manifestWriteFailed {
            manifestFinalizationError = "Earlier manifest writes failed."
        } else if !finishErrors.isEmpty {
            manifestFinalizationError = finishErrors
                .map(\.localizedDescription)
                .joined(separator: "; ")
        }
        // Append event-log flush error (non-fatal, but user-visible).
        if let eventLogFlushError {
            if let existing = manifestFinalizationError {
                manifestFinalizationError = existing + "; " + eventLogFlushError
            } else {
                manifestFinalizationError = eventLogFlushError
            }
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
            result.manifestFinalizationError = manifestFinalizationError
                ?? "The recording manifest was not finalized."
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
        state = .pausing

        await active.eventLogWriter?.stopMonitoring()

        // Stop all capture streams.
        for session in active.sessions {
            await session.stop()
        }

        // Finish the current chunk's writers and collect ended records.
        let chunkWriters = active.writers
        var pauseErrors: [String] = []
        var manifestErrors: [String] = []
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
                    do {
                        try active.manifest.append(.sourceEnded(ended))
                    } catch {
                        manifestErrors.append(error.localizedDescription)
                    }
                case .failure(let error):
                    pauseErrors.append(error.localizedDescription)
                }
            }
        }

        // Record the pause event and accumulate finished writers.
        let pauseHostTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        do {
            try active.manifest.append(.pause(CapturePauseRecord(atUs: pauseHostTimeUs)))
        } catch {
            manifestErrors.append(error.localizedDescription)
        }
        active.writers = []
        active.sessions = []
        if !manifestErrors.isEmpty {
            active.manifestWriteFailed = true
        }
        activeSession = active
        state = .paused

        // Surface any writer finish failures so the UI can report them.
        // The streams are already stopped and the active session has no live
        // writers, so keep the coordinator paused even while reporting the
        // partial pause failure to the UI.
        let errors = pauseErrors + manifestErrors
        if !errors.isEmpty {
            throw CaptureEngineError.captureSessionFailed(
                "Pause encountered capture errors: \(errors.joined(separator: "; "))")
        }
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
        // Use the current target (may have been switched) rather than the
        // original request target.
        let target = active.currentTarget

        var writers: [ContinuousCaptureWriter] = []
        var sessions: [CaptureRunningSession] = []
        let excludedWindowIDs = request.excludedWindowIDs.union(
            floatingPanelWindowID == 0 ? [] : [floatingPanelWindowID])
        var screenVideoWriter: ContinuousCaptureWriter?
        var screenAudioWriter: ContinuousCaptureWriter?

        // Create new writer chunks with unique file names. All sources in one
        // resume cycle share the same chunk index.
        if let target {
            let size = request.target?.outputSize ?? target.outputSize
            let filename = "screen-\(chunkIndex).mov"
            // Reuse the source ID from the header so ended records match.
            let sourceID = Self.screenSourceID(for: target, in: active)
            let source = CaptureSourceDescriptor(
                id: sourceID,
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
                manifest: manifest,
                onSustainedBackpressure: active.onBackpressure)
            writers.append(writer)
            screenVideoWriter = writer
        }

        if request.includeSystemAudio {
            let filename = "system-audio-\(chunkIndex).mov"
            let sourceID = active.sourceIDs[.systemAudio] ?? UUID()
            let source = CaptureSourceDescriptor(
                id: sourceID,
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
                manifest: manifest,
                onSustainedBackpressure: active.onBackpressure)
            writers.append(writer)
            screenAudioWriter = writer
        }

        if let target {
            sessions.append(ScreenCaptureSession(
                target: target,
                frameRate: request.frameRate,
                videoWriter: screenVideoWriter,
                audioWriter: screenAudioWriter,
                captureRegion: request.captureRegion,
                excludingWindowIDs: excludedWindowIDs,
                onStop: active.onStreamStopped))
        }

        if let webcamDeviceID = request.webcamDeviceID {
            let camSize = Self.webcamDimensions(deviceID: webcamDeviceID)
            let bitrate = Self.videoBitrate(width: camSize.width, height: camSize.height, frameRate: request.frameRate)
            let filename = "webcam-\(chunkIndex).mov"
            let sourceID = active.sourceIDs[.webcam] ?? UUID()
            let source = CaptureSourceDescriptor(
                id: sourceID,
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
                manifest: manifest,
                onSustainedBackpressure: active.onBackpressure)
            writers.append(writer)
            sessions.append(AVCaptureSampleSession(deviceID: webcamDeviceID, mediaType: .video, writer: writer))
        }

        if let microphoneDeviceID = request.microphoneDeviceID {
            let filename = "microphone-\(chunkIndex).mov"
            let sourceID = active.sourceIDs[.microphone] ?? UUID()
            let source = CaptureSourceDescriptor(
                id: sourceID,
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
                manifest: manifest,
                onSustainedBackpressure: active.onBackpressure)
            writers.append(writer)
            sessions.append(AVCaptureSampleSession(
                deviceID: microphoneDeviceID,
                mediaType: .audio,
                writer: writer,
                onAudioLevel: active.onMicrophoneLevel))
        }

        // Record resume event.
        let resumeHostTimeUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        do {
            try manifest.append(.resume(CaptureResumeRecord(atUs: resumeHostTimeUs)))
        } catch {
            let cleanupErrors = await Self.finishWritersCollectingErrors(writers)
            var restored = active
            restored.manifestWriteFailed = true
            activeSession = restored
            let cleanupSuffix = cleanupErrors.isEmpty
                ? ""
                : "; cleanup errors: \(cleanupErrors.joined(separator: "; "))"
            throw CaptureEngineError.manifestWriteFailed("\(error.localizedDescription)\(cleanupSuffix)")
        }

        // Update the active session with new writers and sessions.
        // Increment chunk index once for the whole resume cycle.
        var updated = active
        updated.writers = writers
        updated.sessions = sessions
        updated.chunkIndex = chunkIndex + 1
        activeSession = updated

        var startedSessions: [CaptureRunningSession] = []
        do {
            for session in sessions {
                try await session.start()
                startedSessions.append(session)
            }
        } catch {
            // Stop any sessions that were already started before the failure.
            for started in startedSessions {
                await started.stop()
            }
            let cleanupErrors = await Self.finishWritersCollectingErrors(writers)
            // Restore paused state so user can retry or stop.
            var restored = updated
            restored.writers = []
            restored.sessions = []
            if !cleanupErrors.isEmpty {
                restored.manifestWriteFailed = true
            }
            activeSession = restored
            state = .paused
            if !cleanupErrors.isEmpty {
                throw CaptureEngineError.captureSessionFailed(
                    "\(error.localizedDescription); cleanup errors: \(cleanupErrors.joined(separator: "; "))")
            }
            throw error
        }
        state = .recording
        await activeSession?.eventLogWriter?.startMonitoring()
        didStartRecording = true
    }

    /// Switch the capture source mid-session. Updates the screen capture
    /// session's target (content filter + configuration). The first frame after
    /// the switch is dropped to avoid transitional artifacts.
    func updateSource(_ newTarget: CaptureTarget) async throws {
        guard state == .recording, var active = activeSession else {
            throw CaptureEngineError.notRecording
        }
        guard try await Self.updateFirstSwitchableSession(active.sessions, to: newTarget) else {
            throw CaptureEngineError.captureSessionFailed("No screen capture session to update.")
        }
        // Persist the switched target so resume() uses it.
        active.currentTarget = newTarget
        active.startRequest?.captureRegion = nil
        await active.eventLogWriter?.updateTarget(newTarget)
        activeSession = active
    }

    /// The CGWindowID of the floating control panel, used to exclude it from
    /// screen capture. Set by the EditorModel when the panel is shown.
    private var floatingPanelWindowID: CGWindowID = 0

    /// Update the floating panel window ID for capture exclusion.
    func setFloatingPanelWindowID(_ windowID: CGWindowID) async throws {
        guard windowID != 0 else { return }
        floatingPanelWindowID = windowID
        if var active = activeSession {
            active.startRequest?.excludedWindowIDs.insert(windowID)
            activeSession = active
        }
        // Update the live screen-capture filter to exclude the panel.
        guard state == .recording, let active = activeSession else { return }
        _ = try await Self.excludeWindowFromFirstSwitchableSession(active.sessions, windowID: windowID)
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

    private static func screenSourceID(for target: CaptureTarget,
                                       in active: ActiveSession) -> UUID {
        active.sourceIDs[target.sourceKind]
            ?? active.sourceIDs[.display]
            ?? active.sourceIDs[.window]
            ?? active.sourceIDs[.application]
            ?? UUID()
    }

    private static func finishWritersCollectingErrors(_ writers: [ContinuousCaptureWriter]) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for writer in writers {
                group.addTask {
                    do {
                        _ = try await writer.finish()
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }

            var errors: [String] = []
            for await error in group {
                if let error {
                    errors.append(error)
                }
            }
            return errors
        }
    }

    @discardableResult
    static func updateFirstSwitchableSession(_ sessions: [CaptureRunningSession],
                                             to newTarget: CaptureTarget) async throws -> Bool {
        for session in sessions where session.supportsSourceSwitching {
            try await session.updateTarget(newTarget)
            return true
        }
        return false
    }

    @discardableResult
    static func excludeWindowFromFirstSwitchableSession(_ sessions: [CaptureRunningSession],
                                                       windowID: CGWindowID) async throws -> Bool {
        for session in sessions where session.supportsSourceSwitching {
            try await session.excludeWindow(windowID)
            return true
        }
        return false
    }

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
        // H.264 hardware encoders require even dimensions.
        let width = Int(dims.width) & ~1
        let height = Int(dims.height) & ~1
        guard width >= 16, height >= 16 else { return fallback }
        return (width, height)
    }

    private static func videoBitrate(width: Int, height: Int, frameRate: Double) -> Int {
        let pixels = Double(max(1, width * height))
        // Keep roughly 0.08 bits per pixel per frame for real-time H.264,
        // bounded to avoid unusably low 720p output or excessive 4K rates.
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
            // Stereo system audio gets more headroom; mono mic chunks stay small.
            AVEncoderBitRateKey: channels > 1 ? 192_000 : 96_000,
        ]
    }
}
