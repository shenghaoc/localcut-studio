import Foundation
import AVFoundation
import CoreMedia
import os
@preconcurrency import ScreenCaptureKit
import LocalCutCore

protocol CaptureRunningSession: Sendable {
    nonisolated var supportsSourceSwitching: Bool { get }

    func start() async throws
    func stop() async
    func updateTarget(_ newTarget: CaptureTarget) async throws
    func excludeWindow(_ windowID: CGWindowID) async throws
}

extension CaptureRunningSession {
    nonisolated var supportsSourceSwitching: Bool { false }

    func updateTarget(_ newTarget: CaptureTarget) async throws {
        throw CaptureEngineError.captureSessionFailed("This capture session cannot switch sources.")
    }

    func excludeWindow(_ windowID: CGWindowID) async throws {}
}

nonisolated enum CapturePermissionAuthorizer {
    static func requestScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func requestDeviceAccess(for mediaType: AVMediaType) async -> Bool {
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

/// `@unchecked Sendable`: mutable state (`target`, `stream`, writers,
/// `excludingWindowIDs`) is protected by `stateLock`; `dropNextScreenFrame`
/// and delegate callbacks from ScreenCaptureKit are confined to `outputQueue`.
nonisolated final class ScreenCaptureSession: NSObject, CaptureRunningSession, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated var supportsSourceSwitching: Bool { true }

    private let stateLock = OSAllocatedUnfairLock(initialState: ())
    private var target: CaptureTarget
    private let frameRate: Double
    private var videoWriter: ContinuousCaptureWriter?
    private var audioWriter: ContinuousCaptureWriter?
    private var captureRegion: CaptureRegion?
    private let writerCanvasSize: (width: Int, height: Int)?
    private let frameScaler: FrameScaler?
    private let outputQueue = DispatchQueue(label: "com.localcutstudio.capture.screen.output")
    private let onStop: (@Sendable (Error) -> Void)?
    private let onVideoFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var stream: SCStream?
    /// When true, the next `.screen` frame is dropped (used after source switch
    /// to discard the transitional frame).
    private var dropNextScreenFrame = false
    /// Window IDs to exclude from capture (e.g. the floating control panel).
    private var excludingWindowIDs: Set<CGWindowID> = []

    private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        try stateLock.withLockUnchecked { _ in try body() }
    }

    init(target: CaptureTarget,
         frameRate: Double,
         videoWriter: ContinuousCaptureWriter?,
         audioWriter: ContinuousCaptureWriter?,
         captureRegion: CaptureRegion? = nil,
         excludingWindowIDs: Set<CGWindowID> = [],
         onStop: (@Sendable (Error) -> Void)? = nil,
         onVideoFrame: (@Sendable (CVPixelBuffer) -> Void)? = nil) {
        self.target = target
        self.frameRate = frameRate
        self.videoWriter = videoWriter
        self.audioWriter = audioWriter
        self.captureRegion = captureRegion
        if let width = videoWriter?.source.width,
           let height = videoWriter?.source.height {
            self.writerCanvasSize = (width, height)
            self.frameScaler = FrameScaler(targetWidth: width, targetHeight: height)
        } else {
            self.writerCanvasSize = nil
            self.frameScaler = nil
        }
        self.excludingWindowIDs = Set(excludingWindowIDs.filter { $0 != 0 })
        self.onStop = onStop
        self.onVideoFrame = onVideoFrame
    }

    func start() async throws {
        guard CapturePermissionAuthorizer.requestScreenRecordingAccess() else {
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
        withLockedState {
            self.stream = stream
        }
    }

    func stop() async {
        guard let stream = withLockedState({ self.stream }) else { return }
        await withCheckedContinuation { continuation in
            stream.stopCapture { _ in continuation.resume() }
        }
        withLockedState {
            self.stream = nil
        }
    }

    /// Update the capture target mid-session. The stream's content filter and
    /// configuration are updated in-place; the first frame after the switch is
    /// dropped to avoid a transitional artifact.
    func updateTarget(_ newTarget: CaptureTarget) async throws {
        guard let stream = withLockedState({ self.stream }) else { throw CaptureEngineError.notRecording }
        withLockedState {
            self.target = newTarget
            self.captureRegion = nil
        }

        let content = try await SCShareableContent.current
        let newFilter = try makeFilter(from: content)
        let newConfig = makeConfiguration()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.updateContentFilter(newFilter) { error in
                if let error {
                    continuation.resume(throwing: CaptureEngineError.captureSessionFailed(error.localizedDescription))
                } else {
                    stream.updateConfiguration(newConfig) { error in
                        if let error {
                            continuation.resume(throwing: CaptureEngineError.captureSessionFailed(error.localizedDescription))
                        } else {
                            // Set the drop flag AFTER the update completes so the
                            // next frame from the new source (not an in-flight frame
                            // from the old source) is the one dropped.
                            self.outputQueue.async { self.dropNextScreenFrame = true }
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func makeFilter(from content: SCShareableContent) throws -> SCContentFilter {
        let state = withLockedState {
            (target: target, excludingWindowIDs: excludingWindowIDs)
        }
        // Resolve window IDs to SCWindow objects for exclusion.
        let excludedWindows = state.excludingWindowIDs.compactMap { windowID in
            content.windows.first(where: { $0.windowID == windowID })
        }

        switch state.target {
        case .display(let displayID, _, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureEngineError.targetUnavailable
            }
            return SCContentFilter(display: display, excludingWindows: excludedWindows)

        case .window(let windowID, _, _, _, _, _):
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
            return SCContentFilter(display: display, including: [app], exceptingWindows: excludedWindows)
        }
    }

    /// Add a window ID to the exclusion list and update the live capture filter.
    /// Used to exclude the floating control panel from screen capture.
    func excludeWindow(_ windowID: CGWindowID) async throws {
        guard windowID != 0 else { return }
        let runningStream = withLockedState {
            excludingWindowIDs.insert(windowID)
            return stream
        }
        // If the stream is running, update the filter in-place.
        guard let stream = runningStream else { return }
        let content = try await SCShareableContent.current
        let newFilter = try makeFilter(from: content)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.updateContentFilter(newFilter) { error in
                if let error {
                    continuation.resume(throwing: CaptureEngineError.captureSessionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let size = writerCanvasSize ?? withLockedState { target.outputSize }
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(seconds: 1.0 / max(1, frameRate), preferredTimescale: 600)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if let region = withLockedState({ captureRegion }),
           region.applies(to: withLockedState({ target })) {
            configuration.sourceRect = region.sourceRect
        }
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
            // ScreenCaptureKit can deliver idle, blank, or stopped frames during
            // display changes, window transitions, or when the screen is locked.
            // Only pass complete frames to the writer — non-frame buffers produce
            // black/stale frames in the recording or trigger writer failures.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let status = attachments.first?[.status] as? Int,
               status != 0 { return }  // 0 = SCFrameStatus.complete
            // Drop the first frame after a source switch to avoid transitional artifacts.
            if dropNextScreenFrame {
                dropNextScreenFrame = false
                return
            }
            appendScreenSample(sampleBuffer)
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

    private func appendScreenSample(_ sampleBuffer: CMSampleBuffer) {
        guard let videoWriter else { return }
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            videoWriter.append(sampleBuffer)
            return
        }
        guard let writerCanvasSize else {
            videoWriter.append(sampleBuffer)
            onVideoFrame?(sourceBuffer)
            return
        }
        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)
        guard width != writerCanvasSize.width || height != writerCanvasSize.height else {
            videoWriter.append(sampleBuffer)
            onVideoFrame?(sourceBuffer)
            return
        }
        guard let scaledBuffer = frameScaler?.scale(sourceBuffer),
              let scaledSample = Self.makeSampleBuffer(from: scaledBuffer, timingFrom: sampleBuffer) else {
            return
        }
        videoWriter.append(scaledSample)
        onVideoFrame?(scaledBuffer)
    }

    private static func makeSampleBuffer(from imageBuffer: CVPixelBuffer,
                                         timingFrom source: CMSampleBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription)
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(source))
        var output: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &output)
        guard sampleStatus == noErr else { return nil }
        return output
    }
}

/// `@unchecked Sendable`: mutable `processorState` and `lastAudioLevelEmission`
/// are touched only inside AVFoundation delegate callbacks confined to `queue`.
nonisolated final class AVCaptureSampleSession: NSObject, CaptureRunningSession, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deviceID: String
    private let mediaType: AVMediaType
    private let writer: ContinuousCaptureWriter
    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let onAudioLevel: (@Sendable (Float) -> Void)?
    private let onVideoFrame: (@Sendable (CVPixelBuffer) -> Void)?
    /// Voice cleanup settings for mic recording path. When non-nil, audio
    /// buffers are processed through VoiceCleanupDSP before encoding.
    private let voiceCleanupSettings: LiveVoiceCleanupSettingsStore?
    private var processorState = VoiceCleanupProcessorState()
    private var lastAudioLevelEmission = CFAbsoluteTimeGetCurrent()

    init(deviceID: String,
         mediaType: AVMediaType,
         writer: ContinuousCaptureWriter,
         onAudioLevel: (@Sendable (Float) -> Void)? = nil,
         onVideoFrame: (@Sendable (CVPixelBuffer) -> Void)? = nil,
         voiceCleanupSettings: LiveVoiceCleanupSettingsStore? = nil) {
        self.deviceID = deviceID
        self.mediaType = mediaType
        self.writer = writer
        self.onAudioLevel = onAudioLevel
        self.onVideoFrame = onVideoFrame
        self.voiceCleanupSettings = voiceCleanupSettings
        self.queue = DispatchQueue(label: "com.localcutstudio.capture.av.\(deviceID)")
        super.init()
    }

    func start() async throws {
        guard await CapturePermissionAuthorizer.requestDeviceAccess(for: mediaType) else {
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
        if mediaType == .audio,
           let onAudioLevel,
           let level = Self.audioPeakLevel(from: sampleBuffer) {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastAudioLevelEmission >= 0.05 {
                lastAudioLevelEmission = now
                onAudioLevel(level)
            }
        }

        // Apply voice cleanup DSP to mic audio before encoding. This ensures
        // the recording path has the same inserts as the monitor path.
        if mediaType == .audio, let settingsStore = voiceCleanupSettings {
            let settings = settingsStore.read()
            if Self.hasActiveInserts(settings) {
                let processed = Self.processAudioCleanup(sampleBuffer, settings: settings, state: &processorState)
                writer.append(processed ?? sampleBuffer)
            } else {
                writer.append(sampleBuffer)
            }
        } else {
            writer.append(sampleBuffer)
        }

        if mediaType == .video,
           let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            onVideoFrame?(buffer)
        }
    }

    /// Returns true if any voice cleanup insert is active (not fully bypassed).
    private static func hasActiveInserts(_ settings: VoiceCleanupSettings) -> Bool {
        !settings.denoiser.bypass || !settings.gate.bypass
            || !settings.compressor.bypass || !settings.limiter.bypass
            || settings.loudness.enabled
    }

    /// Processes a CMSampleBuffer through VoiceCleanupDSP. Returns a new
    /// CMSampleBuffer with processed samples, or nil if processing fails.
    ///
    /// Handles Int16, Int32, and Float32 input formats by converting to
    /// Float32 for DSP processing. Preserves interleaved layout.
    private static func processAudioCleanup(_ sampleBuffer: CMSampleBuffer,
                                            settings: VoiceCleanupSettings,
                                            state: inout VoiceCleanupProcessorState) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // Create a Float32 PCM buffer for processing.
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: true) else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        // Extract samples from the source buffer, converting to Float32
        // as needed. CMSampleBufferCopyPCMDataIntoAudioBufferList handles
        // the conversion when the target format differs from the source.
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList)
        guard copyStatus == noErr else { return nil }

        // Extract interleaved float samples from channelData[0], which
        // for an interleaved format is the single contiguous buffer
        // containing all channels interleaved.
        guard let channelData = pcmBuffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        let totalSamples = Int(frameCount) * channels
        guard channels > 0, totalSamples > 0 else { return nil }
        var interleaved = [Float](repeating: 0, count: totalSamples)
        let didCopySamples = interleaved.withUnsafeMutableBufferPointer { ptr -> Bool in
            guard let destination = ptr.baseAddress else { return false }
            destination.update(from: channelData[0], count: totalSamples)
            return true
        }
        guard didCopySamples else { return nil }

        // Process through VoiceCleanupDSP.
        let sampleRate = format.sampleRate
        VoiceCleanupDSP.processInterleaved(
            &interleaved, channels: channels, sampleRate: sampleRate,
            settings: settings, state: &state)

        // Write processed interleaved Float32 data back to channelData[0].
        let didWriteSamples = interleaved.withUnsafeBufferPointer { ptr -> Bool in
            guard let source = ptr.baseAddress else { return false }
            channelData[0].update(from: source, count: totalSamples)
            return true
        }
        guard didWriteSamples else { return nil }

        // Create a format description for the output (interleaved Float32).
        var outputFormatDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: floatFormat.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &outputFormatDesc)
        guard fmtStatus == noErr, let outFmtDesc = outputFormatDesc else { return nil }

        // Create new CMSampleBuffer with the Float32 format description.
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer))
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: outFmtDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &output)
        guard status == noErr, let createdBuffer = output else { return nil }

        // Use the block buffer to carry the processed audio data.
        let audioBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let dataLength = audioBuffers.reduce(0) { result, buffer in
            result + Int(buffer.mDataByteSize)
        }
        guard dataLength > 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard bbStatus == noErr, let blockBuffer else { return nil }

        // Copy from the PCM buffer's AudioBufferList so the block payload
        // matches the format description's declared layout.
        var offset = 0
        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else { return nil }
            let size = Int(audioBuffer.mDataByteSize)
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: data,
                blockBuffer: blockBuffer,
                offsetIntoDestination: offset,
                dataLength: size)
            guard copyStatus == noErr else { return nil }
            offset += size
        }
        guard offset == dataLength else { return nil }

        // Set the block buffer on the sample buffer.
        let setBB = CMSampleBufferSetDataBuffer(createdBuffer, newValue: blockBuffer)
        guard setBB == noErr else { return nil }

        return createdBuffer
    }

    nonisolated static func audioPeakLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return normalizedPeak(from: pcmBuffer)
    }

    nonisolated static func normalizedPeak(from buffer: AVAudioPCMBuffer) -> Float? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        var peak: Float = 0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    peak = max(peak, abs(channelData[channel][frame]))
                }
            }
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    peak = max(peak, abs(Float(channelData[channel][frame])) / Float(Int16.max))
                }
            }
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return nil }
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    peak = max(peak, abs(Float(channelData[channel][frame])) / Float(Int32.max))
                }
            }
        default:
            return nil
        }
        return min(1, peak)
    }
}
