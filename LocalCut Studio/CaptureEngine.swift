import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import VideoToolbox
import LocalCutCore

nonisolated enum CaptureEngineError: LocalizedError {
    case alreadyRecording
    case notRecording
    case noCaptureSources
    case targetUnavailable
    case writerRejectedInput(String)
    case writerStartFailed(String)
    case writerFinishFailed(String)
    case screenRecordingDenied
    case cameraUnavailable
    case microphoneUnavailable
    case captureSessionFailed(String)
    case manifestWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "A recording is already running."
        case .notRecording:
            "No recording is running."
        case .noCaptureSources:
            "Select at least one recording source."
        case .targetUnavailable:
            "The selected screen, window, or app is no longer available."
        case .writerRejectedInput(let source):
            "The recorder could not add a writer input for \(source)."
        case .writerStartFailed(let reason):
            "The recorder could not start writing: \(reason)"
        case .writerFinishFailed(let reason):
            "The recorder could not finish writing: \(reason)"
        case .screenRecordingDenied:
            "Screen recording permission is required. Enable LocalCut Studio in System Settings."
        case .cameraUnavailable:
            "The selected camera is unavailable."
        case .microphoneUnavailable:
            "The selected microphone is unavailable."
        case .captureSessionFailed(let reason):
            "Capture failed: \(reason)"
        case .manifestWriteFailed(let reason):
            "Could not update the recording manifest: \(reason)"
        }
    }
}

nonisolated struct CaptureSourceOption: Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var target: CaptureTarget
    var width: Int
    var height: Int
}

nonisolated enum CaptureTarget: Hashable, Sendable {
    case display(displayID: UInt32, width: Int, height: Int)
    case window(windowID: UInt32, title: String, owner: String, width: Int, height: Int)
    case application(processID: Int32, bundleIdentifier: String, name: String, displayID: UInt32, width: Int, height: Int)

    var sourceKind: CaptureSourceKind {
        switch self {
        case .display: .display
        case .window: .window
        case .application: .application
        }
    }

    var displayName: String {
        switch self {
        case .display(let displayID, _, _):
            "Display \(displayID)"
        case .window(_, let title, let owner, _, _):
            title.isEmpty ? owner : "\(owner) — \(title)"
        case .application(_, _, let name, _, _, _):
            name
        }
    }

    var outputSize: (width: Int, height: Int) {
        switch self {
        case .display(_, let width, let height),
             .window(_, _, _, let width, let height),
             .application(_, _, _, _, let width, let height):
            // VideoToolbox H.264/HEVC hardware encoders require even dimensions;
            // round down to the nearest even number to avoid AVAssetWriter failures.
            (max(16, width) & ~1, max(16, height) & ~1)
        }
    }
}

nonisolated struct CaptureDeviceOption: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
}

nonisolated struct CaptureStartRequest: Sendable {
    var target: CaptureTarget?
    var includeSystemAudio: Bool
    var webcamDeviceID: String?
    var microphoneDeviceID: String?
    var rootURL: URL
    var frameRate: Double
    var fragmentInterval: CMTime
    var capabilities: Capabilities
}

nonisolated struct CaptureSessionResult: Sendable, Identifiable {
    let id: UUID
    var directoryURL: URL
    var manifestURL: URL
    var manifest: CaptureManifest
    var wasRecovered: Bool
}

enum CaptureSourceCatalog {
    @MainActor
    static func screenOptions() async throws -> [CaptureSourceOption] {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureEngineError.screenRecordingDenied
        }

        let content = try await SCShareableContent.current
        var options: [CaptureSourceOption] = []

        for display in content.displays {
            let width = max(16, display.width)
            let height = max(16, display.height)
            options.append(CaptureSourceOption(
                id: "display-\(display.displayID)",
                title: "Display \(display.displayID)",
                subtitle: "\(width) x \(height)",
                target: .display(displayID: display.displayID, width: width, height: height),
                width: width,
                height: height))
        }

        for window in content.windows where window.isOnScreen {
            let owner = window.owningApplication?.applicationName ?? "Window"
            let title = window.title ?? ""
            let width = max(16, Int(window.frame.width.rounded()))
            let height = max(16, Int(window.frame.height.rounded()))
            options.append(CaptureSourceOption(
                id: "window-\(window.windowID)",
                title: title.isEmpty ? owner : title,
                subtitle: owner,
                target: .window(windowID: window.windowID, title: title, owner: owner, width: width, height: height),
                width: width,
                height: height))
        }

        let firstDisplay = content.displays.first
        for application in content.applications {
            guard let display = firstDisplay else { continue }
            let width = max(16, display.width)
            let height = max(16, display.height)
            options.append(CaptureSourceOption(
                id: "app-\(application.processID)",
                title: application.applicationName,
                subtitle: application.bundleIdentifier,
                target: .application(
                    processID: application.processID,
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.applicationName,
                    displayID: display.displayID,
                    width: width,
                    height: height),
                width: width,
                height: height))
        }

        return options
    }

    @MainActor
    static func webcamOptions() -> [CaptureDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified)
        return discovery.devices.map { CaptureDeviceOption(id: $0.uniqueID, title: $0.localizedName) }
    }

    @MainActor
    static func microphoneOptions() -> [CaptureDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external],
            mediaType: .audio,
            position: .unspecified)
        return discovery.devices.map { CaptureDeviceOption(id: $0.uniqueID, title: $0.localizedName) }
    }
}

nonisolated final class CaptureManifestFileWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.localcutstudio.capture.manifest")
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func append(_ record: CaptureManifestRecord) throws {
        let line = try CaptureManifest.lineData(for: record)
        try queue.sync {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        }
    }

    func close() {
        queue.sync {
            try? handle.close()
        }
    }
}

nonisolated final class ContinuousCaptureWriter: @unchecked Sendable {
    let source: CaptureSourceDescriptor
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let sessionStartHostTimeUs: Int64
    private let manifest: CaptureManifestFileWriter
    private let lock = NSLock()

    private var didStartWriting = false
    private var isFinished = false
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var sampleCount = 0
    private var droppedSamples = 0
    private var didRecordBackpressure = false

    init(source: CaptureSourceDescriptor,
         outputURL: URL,
         mediaType: AVMediaType,
         outputSettings: [String: Any],
         fragmentInterval: CMTime,
         sessionStartHostTimeUs: Int64,
         manifest: CaptureManifestFileWriter) throws {
        self.source = source
        self.outputURL = outputURL
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        self.writer.movieFragmentInterval = fragmentInterval
        self.input = AVAssetWriterInput(mediaType: mediaType, outputSettings: outputSettings)
        self.input.expectsMediaDataInRealTime = true
        self.sessionStartHostTimeUs = sessionStartHostTimeUs
        self.manifest = manifest

        guard writer.canAdd(input) else {
            throw CaptureEngineError.writerRejectedInput(source.displayName)
        }
        writer.add(input)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(sampleBuffer)
    }

    private func appendLocked(_ sampleBuffer: CMSampleBuffer) {
        // Once finalized (or a fatal writer failure occurred) discard any
        // late-arriving buffers; appending to a finished/failed writer crashes.
        guard !isFinished else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.isIndefinite else { return }

        if !didStartWriting {
            guard writer.startWriting() else {
                recordBackpressure(reason: writer.error?.localizedDescription ?? "writer.startWriting failed")
                // A failed AVAssetWriter cannot recover; stop attempting on
                // every subsequent frame.
                isFinished = true
                return
            }
            writer.startSession(atSourceTime: pts)
            firstPresentationTime = pts
            didStartWriting = true
        }

        guard input.isReadyForMoreMediaData else {
            droppedSamples += 1
            recordBackpressure(reason: "writer input was not ready")
            return
        }

        if input.append(sampleBuffer) {
            sampleCount += 1
            lastPresentationTime = pts
        } else {
            droppedSamples += 1
            recordBackpressure(reason: writer.error?.localizedDescription ?? "append failed")
        }
    }

    private func recordBackpressure(reason: String) {
        guard !didRecordBackpressure else { return }
        didRecordBackpressure = true
        let atUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let record = CaptureBackpressureRecord(
            sourceID: source.id,
            atUs: atUs,
            droppedSamples: max(1, droppedSamples),
            reason: reason)
        try? manifest.append(.backpressure(record))
    }

    func finish() async throws -> CaptureSourceEndedRecord {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // Block any concurrent late buffers before finalizing the input.
            isFinished = true
            input.markAsFinished()

            guard didStartWriting else {
                writer.cancelWriting()
                let record = endedRecord(durationUs: 0)
                lock.unlock()
                continuation.resume(returning: record)
                return
            }

            let record = endedRecord(durationUs: durationUs())
            lock.unlock()
            writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: CaptureEngineError.writerFinishFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: record)
                }
            }
        }
    }

    private func endedRecord(durationUs: Int64) -> CaptureSourceEndedRecord {
        CaptureSourceEndedRecord(
            sourceID: source.id,
            atUs: CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock())),
            durationUs: durationUs,
            timelineStartUs: timelineStartUs(),
            sampleCount: sampleCount)
    }

    private func durationUs() -> Int64 {
        guard let firstPresentationTime, let lastPresentationTime else { return 0 }
        return CaptureManifest.microseconds(from: lastPresentationTime - firstPresentationTime)
    }

    private func timelineStartUs() -> Int64 {
        guard let firstPresentationTime else { return source.timelineStartUs }
        let firstUs = CaptureManifest.microseconds(from: firstPresentationTime)
        return max(0, firstUs - sessionStartHostTimeUs)
    }
}

protocol CaptureRunningSession: Sendable {
    func start() async throws
    func stop() async
}

nonisolated final class ScreenCaptureSession: NSObject, CaptureRunningSession, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let target: CaptureTarget
    private let frameRate: Double
    private let videoWriter: ContinuousCaptureWriter?
    private let audioWriter: ContinuousCaptureWriter?
    private let outputQueue = DispatchQueue(label: "com.localcutstudio.capture.screen.output")
    private let onStop: (@Sendable (Error) -> Void)?
    private var stream: SCStream?

    init(target: CaptureTarget,
         frameRate: Double,
         videoWriter: ContinuousCaptureWriter?,
         audioWriter: ContinuousCaptureWriter?,
         onStop: (@Sendable (Error) -> Void)? = nil) {
        self.target = target
        self.frameRate = frameRate
        self.videoWriter = videoWriter
        self.audioWriter = audioWriter
        self.onStop = onStop
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureEngineError.screenRecordingDenied
        }

        let content = try await SCShareableContent.current
        let filter = try makeFilter(from: content)
        let configuration = makeConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        if videoWriter != nil {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        }
        if audioWriter != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: CaptureEngineError.captureSessionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        await withCheckedContinuation { continuation in
            stream.stopCapture { _ in continuation.resume() }
        }
        self.stream = nil
    }

    private func makeFilter(from content: SCShareableContent) throws -> SCContentFilter {
        switch target {
        case .display(let displayID, _, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureEngineError.targetUnavailable
            }
            return SCContentFilter(display: display, excludingWindows: [])

        case .window(let windowID, _, _, _, _):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureEngineError.targetUnavailable
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .application(let processID, let bundleIdentifier, _, let displayID, _, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first,
                  let app = content.applications.first(where: {
                      $0.processID == processID || $0.bundleIdentifier == bundleIdentifier
                  }) else {
                throw CaptureEngineError.targetUnavailable
            }
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let size = target.outputSize
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(seconds: 1.0 / max(1, frameRate), preferredTimescale: 600)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = audioWriter != nil
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            videoWriter?.append(sampleBuffer)
        case .audio:
            audioWriter?.append(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The stream stopped unexpectedly (window closed, permission revoked,
        // etc.). Surface it so the UI can stop the recording and inform the user.
        onStop?(error)
    }
}

nonisolated final class AVCaptureSampleSession: NSObject, CaptureRunningSession, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deviceID: String
    private let mediaType: AVMediaType
    private let writer: ContinuousCaptureWriter
    private let session = AVCaptureSession()
    private let queue: DispatchQueue

    init(deviceID: String, mediaType: AVMediaType, writer: ContinuousCaptureWriter) {
        self.deviceID = deviceID
        self.mediaType = mediaType
        self.writer = writer
        self.queue = DispatchQueue(label: "com.localcutstudio.capture.av.\(deviceID)")
        super.init()
    }

    func start() async throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw mediaType == .video ? CaptureEngineError.cameraUnavailable : CaptureEngineError.microphoneUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        // Only video sessions benefit from a quality preset; setting it on an
        // audio-only session is unsupported and can fail.
        if mediaType == .video, session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureEngineError.captureSessionFailed("Input rejected for \(device.localizedName)")
        }
        session.addInput(input)

        if mediaType == .video {
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CaptureEngineError.captureSessionFailed("Video output rejected for \(device.localizedName)")
            }
            session.addOutput(output)
        } else {
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CaptureEngineError.captureSessionFailed("Audio output rejected for \(device.localizedName)")
            }
            session.addOutput(output)
        }

        session.commitConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.session.startRunning()
                // startRunning() is fire-and-forget; if the device is busy or
                // access was revoked the session silently fails to start.
                if self.session.isRunning {
                    continuation.resume()
                } else {
                    let kind = self.mediaType == .video ? "camera" : "microphone"
                    continuation.resume(throwing: CaptureEngineError.captureSessionFailed(
                        "The \(kind) session failed to start (device may be in use)."))
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        writer.append(sampleBuffer)
    }
}

actor CaptureCoordinator {
    private struct ActiveSession {
        var id: UUID
        var directoryURL: URL
        var manifestURL: URL
        var manifest: CaptureManifestFileWriter
        var sessions: [CaptureRunningSession]
        var writers: [ContinuousCaptureWriter]
        var startHostTimeUs: Int64
    }

    private var activeSession: ActiveSession?

    func start(_ request: CaptureStartRequest,
               onStreamStopped: (@Sendable (Error) -> Void)? = nil) async throws {
        guard activeSession == nil else { throw CaptureEngineError.alreadyRecording }
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

        let id = UUID()
        let directoryURL = request.rootURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
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
                manifest: manifest)
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
                manifest: manifest)
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
                manifest: manifest)
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
                manifest: manifest)
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
            startHostTimeUs: startHostTimeUs)
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
            activeSession = nil
            throw error
        }
    }

    func stop() async throws -> CaptureSessionResult {
        guard let active = activeSession else { throw CaptureEngineError.notRecording }
        activeSession = nil

        for session in active.sessions {
            await session.stop()
        }

        // Finish every writer even if one fails, so no FileHandle or fragmented
        // .mov is left open, and always write the finalize record + close the
        // manifest. Surface the first failure to the caller afterwards.
        var finishErrors: [Error] = []
        for writer in active.writers {
            do {
                let ended = try await writer.finish()
                try active.manifest.append(.sourceEnded(ended))
            } catch {
                finishErrors.append(error)
            }
        }
        let durationUs = max(
            0,
            CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock())) - active.startHostTimeUs)
        try? active.manifest.append(.finalize(CaptureFinalizeRecord(
            atUs: active.startHostTimeUs + durationUs,
            durationUs: durationUs)))
        active.manifest.close()

        if let firstError = finishErrors.first {
            throw firstError
        }

        let data = try Data(contentsOf: active.manifestURL)
        let parsed = CaptureManifest.parseNDJSON(data)
        return CaptureSessionResult(
            id: active.id,
            directoryURL: active.directoryURL,
            manifestURL: active.manifestURL,
            manifest: parsed,
            wasRecovered: false)
    }

    func scanRecoveredSessions(rootURL: URL) throws -> [CaptureSessionResult] {
        // A live recording's manifest isn't finalized yet; don't mistake it for
        // a crashed session.
        let activeID = activeSession?.id
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
