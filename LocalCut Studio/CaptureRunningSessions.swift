import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

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
        guard await requestAuthorizationIfNeeded() else {
            throw mediaType == .video
                ? CaptureEngineError.cameraPermissionDenied
                : CaptureEngineError.microphonePermissionDenied
        }
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

    private func requestAuthorizationIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
