import Foundation
import os

#if LOCALCUT_ENABLE_WEBRTC
import WebRTC
#endif

// MARK: - AudioPublishBridge

/// Bridges the master-bus audio output to the WebRTC audio pipeline.
///
/// The master bus (post Phase 36 voice-cleanup inserts) pushes
/// interleaved float samples via `pushSamples(_:sampleRate:channels:)`.
/// A dedicated capture thread reads from the ring buffer and delivers
/// fixed-size 10 ms frames at the cadence WebRTC expects.
///
/// WHIP is `sendonly`, so outbound audio rides the ADM capture /
/// recording transport (`RTCAudioDevice.deliverRecordedData`), NOT
/// the playout path.
actor AudioPublishBridge {
    private static let frameDurationSeconds: Double = 0.01
    private var isRunning = false
    private var sampleRate: Double = 48_000
    private var channels: Int = 2
    private var captureThread: Thread?
    private var stopToken: AudioCaptureStopToken?

    #if LOCALCUT_ENABLE_WEBRTC
    /// The custom audio device injected into the peer connection factory.
    private var audioDevice: LocalCutAudioDevice?
    #endif

    private struct SharedState {
        var ringBuffer: RingBuffer?
        #if !LOCALCUT_ENABLE_WEBRTC
        var latestBuffer: [Float]?
        var latestSampleRate: Double = 0
        var latestChannels: Int = 0
        #endif
    }
    private let sharedState = OSAllocatedUnfairLock(initialState: SharedState())

    // Diagnostics
    private let deliveredFrames = OSAllocatedUnfairLock(initialState: 0)
    private let droppedFrames = OSAllocatedUnfairLock(initialState: 0)

    #if !LOCALCUT_ENABLE_WEBRTC
    nonisolated var latestBuffer: [Float]? { sharedState.withLock { $0.latestBuffer } }
    nonisolated var latestSampleRate: Double { sharedState.withLock { $0.latestSampleRate } }
    nonisolated var latestChannels: Int { sharedState.withLock { $0.latestChannels } }
    #endif

    init() {}

    #if LOCALCUT_ENABLE_WEBRTC
    /// Returns the custom audio device for injection into the peer connection factory.
    /// Returns nil when the bridge is not running.
    var rtcAudioDevice: LocalCutAudioDevice? {
        audioDevice
    }
    #endif

    func start(sampleRate: Double, channels: Int) {
        guard !isRunning else { return }
        self.sampleRate = sampleRate
        self.channels = channels
        self.isRunning = true
        let frameSize = Int(sampleRate * Self.frameDurationSeconds) * channels
        let newRing = RingBuffer(capacity: frameSize * 10)
        let token = AudioCaptureStopToken()
        sharedState.withLock { $0.ringBuffer = newRing }
        stopToken = token
        deliveredFrames.withLock { $0 = 0 }
        droppedFrames.withLock { $0 = 0 }

        #if LOCALCUT_ENABLE_WEBRTC
        let device = LocalCutAudioDevice(
            sampleRate: sampleRate,
            channels: channels,
            frameDurationSeconds: Self.frameDurationSeconds
        )
        audioDevice = device
        // Start the capture thread that feeds samples to the device.
        startCaptureThread(frameSize: frameSize, ring: newRing, device: device, stopToken: token)
        #else
        startCaptureThread(frameSize: frameSize, ring: newRing, stopToken: token)
        #endif
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopToken?.stop()
        let thread = captureThread
        thread?.cancel()
        captureThread = nil
        stopToken = nil
        waitForCaptureThreadToExit(thread)
        sharedState.withLock { $0.ringBuffer = nil }
        #if LOCALCUT_ENABLE_WEBRTC
        audioDevice = nil
        #endif
    }

    nonisolated func pushSamples(_ buffer: [Float], sampleRate: Double, channels: Int) {
        sharedState.withLock { s in
            guard let ring = s.ringBuffer else { return }
            ring.write(buffer)
            #if !LOCALCUT_ENABLE_WEBRTC
            s.latestBuffer = buffer
            s.latestSampleRate = sampleRate
            s.latestChannels = channels
            #endif
        }
    }

    // MARK: - Capture thread

    #if LOCALCUT_ENABLE_WEBRTC
    private func startCaptureThread(frameSize: Int, ring: RingBuffer, device: LocalCutAudioDevice, stopToken: AudioCaptureStopToken) {
        let delivered = deliveredFrames
        let dropped = droppedFrames
        let thread = Thread {
            var frameBuffer = [Float](repeating: 0, count: frameSize)
            while true {
                if stopToken.isStopped || Thread.current.isCancelled { break }
                Thread.sleep(forTimeInterval: Self.frameDurationSeconds)
                let readSamples = ring.read(count: frameSize)
                if readSamples.isEmpty {
                    dropped.withLock { $0 += 1 }
                    continue
                }
                for i in 0..<readSamples.count { frameBuffer[i] = readSamples[i] }
                for i in readSamples.count..<frameSize { frameBuffer[i] = 0 }
                device.deliverSamples(frameBuffer)
                delivered.withLock { $0 += 1 }
            }
        }
        thread.name = "com.localcut.whip-audio-capture"
        thread.qualityOfService = .userInitiated
        captureThread = thread
        thread.start()
    }
    #else
    private func startCaptureThread(frameSize: Int, ring: RingBuffer, stopToken: AudioCaptureStopToken) {
        let thread = Thread {
            var frameBuffer = [Float](repeating: 0, count: frameSize)
            while true {
                if stopToken.isStopped || Thread.current.isCancelled { break }
                Thread.sleep(forTimeInterval: Self.frameDurationSeconds)
                let readSamples = ring.read(count: frameSize)
                for i in 0..<readSamples.count { frameBuffer[i] = readSamples[i] }
                for i in readSamples.count..<frameSize { frameBuffer[i] = 0 }
            }
        }
        thread.name = "com.localcut.whip-audio-capture"
        thread.qualityOfService = .userInitiated
        captureThread = thread
        thread.start()
    }
    #endif

    private nonisolated func waitForCaptureThreadToExit(_ thread: Thread?) {
        guard let thread else { return }
        let deadline = Date().addingTimeInterval(0.25)
        while thread.isExecuting && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

private nonisolated final class AudioCaptureStopToken: @unchecked Sendable {
    private let stopped = OSAllocatedUnfairLock<Bool>(initialState: false)

    var isStopped: Bool { stopped.withLock { $0 } }

    func stop() {
        stopped.withLock { $0 = true }
    }
}

// MARK: - LocalCutAudioDevice (RTCAudioDevice)

#if LOCALCUT_ENABLE_WEBRTC
/// Custom `RTCAudioDevice` that feeds master-bus samples into WebRTC's
/// capture/recording transport.
///
/// The device is `sendonly` — playout is inert (returns silence).
/// Recording samples are delivered via `deliverSamples(_:)` from the
/// capture thread, which calls the delegate's `deliverRecordedData`
/// block to push PCM into WebRTC's native ADM.
nonisolated final class LocalCutAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    private let sampleRate: Double
    private let channels: Int
    private let frameDurationSeconds: Double

    private var delegate: RTCAudioDeviceDelegate?
    private var isRecordingActive = false
    private var isPlayoutActive = false

    // Diagnostics
    private let deliveredCount = OSAllocatedUnfairLock(initialState: 0)

    init(sampleRate: Double, channels: Int, frameDurationSeconds: Double) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameDurationSeconds = frameDurationSeconds
        super.init()
    }

    // MARK: - RTCAudioDevice properties

    var deviceInputSampleRate: Double { sampleRate }
    var inputIOBufferDuration: TimeInterval { frameDurationSeconds }
    var inputNumberOfChannels: Int { channels }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { sampleRate }
    var outputIOBufferDuration: TimeInterval { frameDurationSeconds }
    var outputNumberOfChannels: Int { channels }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { delegate != nil }
    var isPlayoutInitialized: Bool { true }
    var isPlaying: Bool { isPlayoutActive }
    var isRecordingInitialized: Bool { true }
    var isRecording: Bool { isRecordingActive }

    // MARK: - Lifecycle

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        return true
    }

    func terminateDevice() -> Bool {
        delegate = nil
        return true
    }

    // MARK: - Playout (inert — sendonly session)

    func initializePlayout() -> Bool { true }

    func startPlayout() -> Bool {
        isPlayoutActive = true
        return true
    }

    func stopPlayout() -> Bool {
        isPlayoutActive = false
        return true
    }

    // MARK: - Recording (active — feeds samples to WebRTC)

    func initializeRecording() -> Bool { true }

    func startRecording() -> Bool {
        isRecordingActive = true
        return true
    }

    func stopRecording() -> Bool {
        isRecordingActive = false
        return true
    }

    // MARK: - Sample delivery

    /// Called from the capture thread to deliver audio samples to WebRTC.
    /// Converts float samples to Int16 and calls the delegate's
    /// `deliverRecordedData` block.
    func deliverSamples(_ samples: [Float]) {
        guard isRecordingActive, let delegate else { return }

        let frameCount = samples.count / channels
        guard frameCount > 0 else { return }

        // Convert float [-1.0, 1.0] to Int16
        var int16Samples = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            int16Samples[i] = Int16(clamped * 32767.0)
        }

        var actionFlags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp(
            mSampleTime: 0,
            mHostTime: 0,
            mRateScalar: 0,
            mWordClockTime: 0,
            mSMPTETime: SMPTETime(),
            mFlags: .sampleTimeValid,
            mReserved: 0
        )

        // Call the delegate's deliverRecordedData block
        let deliverBlock = delegate.deliverRecordedData
        int16Samples.withUnsafeMutableBytes { rawBuffer in
            let audioBuffer = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(rawBuffer.count),
                mData: rawBuffer.baseAddress
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            _ = deliverBlock(&actionFlags, &timestamp, 0, UInt32(frameCount), &bufferList, nil, nil)
        }

        deliveredCount.withLock { $0 += 1 }
    }

    /// Number of frames delivered (diagnostic).
    var totalDeliveredFrames: Int {
        deliveredCount.withLock { $0 }
    }
}
#endif
