import Foundation
import os
import AVFAudio
@preconcurrency import WebRTC

/// Bridges post-master-bus interleaved Float32 samples into WebRTC.
///
/// The portable state is a lock-protected ring buffer. In the WebRTC build,
/// `LocalCutAudioDeviceModuleDelegate` replaces the candidate SDK's physical
/// input node with an `AVAudioSourceNode`; WebRTC owns the render cadence and
/// sample conversion through its public AVAudioEngine device-module API.
public actor AudioPublishBridge {
    private var isRunning = false
    private var sampleRate: Double = 48_000
    private var channels: Int = 2

    private struct SharedState {
        var ringBuffer: RingBuffer?
    }

    private let sharedState = OSAllocatedUnfairLock(initialState: SharedState())

    public init() {}

    public func start(sampleRate: Double, channels: Int) {
        guard !isRunning, sampleRate > 0, channels > 0 else { return }
        self.sampleRate = sampleRate
        self.channels = channels
        isRunning = true

        // Hold 100 ms. Overflow drops the oldest samples, keeping publish
        // latency bounded if WebRTC temporarily stops requesting input.
        let capacity = max(1, Int(sampleRate * 0.1) * channels)
        sharedState.withLock { state in
            state.ringBuffer = RingBuffer(capacity: capacity)
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        sharedState.withLock { state in
            state.ringBuffer = nil
        }
    }

    public nonisolated func pushSamples(_ buffer: [Float], sampleRate: Double, channels: Int) {
        sharedState.withLock { state in
            guard let ring = state.ringBuffer else { return }
            ring.write(buffer)
        }
    }

    func makeAudioDeviceModuleDelegate() -> LocalCutAudioDeviceModuleDelegate? {
        guard isRunning,
              let ring = sharedState.withLock({ $0.ringBuffer }) else { return nil }
        return LocalCutAudioDeviceModuleDelegate(
            ring: ring,
            sampleRate: sampleRate,
            channels: channels)
    }
}

/// Supplies LocalCut's master-bus samples through webrtc-sdk's supported
/// AVAudioEngine input hook. WebRTC calls this delegate on its worker thread.
nonisolated final class LocalCutAudioDeviceModuleDelegate:
    NSObject, RTCAudioDeviceModuleDelegate, @unchecked Sendable
{
    private let sourceFormat: AVAudioFormat
    private let renderer: LocalCutAudioSourceRenderer
    private var sourceNode: AVAudioSourceNode?

    init?(ring: RingBuffer, sampleRate: Double, channels: Int) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false)
        else { return nil }

        sourceFormat = format
        renderer = LocalCutAudioSourceRenderer(ring: ring, channels: channels)
        super.init()
    }

    func audioDeviceModule(
        _: RTCAudioDeviceModule,
        engine: AVAudioEngine,
        configureInputFromSource _: AVAudioNode?,
        toDestination destination: AVAudioNode,
        format _: AVAudioFormat,
        context _: [AnyHashable: Any]
    ) -> Int {
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }

        let renderer = renderer
        let sourceNode = AVAudioSourceNode(format: sourceFormat) {
            _, _, frameCount, outputData in
            renderer.render(frameCount: frameCount, outputData: outputData)
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: destination, format: sourceFormat)
        self.sourceNode = sourceNode
        return 0
    }

    func audioDeviceModule(
        _: RTCAudioDeviceModule,
        engine _: AVAudioEngine,
        configureOutputFromSource _: AVAudioNode,
        toDestination _: AVAudioNode?,
        format _: AVAudioFormat,
        context _: [AnyHashable: Any]
    ) -> Int { 0 }

    func audioDeviceModule(
        _: RTCAudioDeviceModule,
        didReceiveSpeechActivityEvent _: RTCSpeechActivityEvent
    ) {}

    func audioDeviceModuleDidUpdateDevices(_: RTCAudioDeviceModule) {}

    func audioDeviceModule(_: RTCAudioDeviceModule, didCreateEngine _: AVAudioEngine) -> Int { 0 }

    func audioDeviceModule(
        _: RTCAudioDeviceModule,
        willEnableEngine _: AVAudioEngine,
        isPlayoutEnabled _: Bool,
        isRecordingEnabled _: Bool
    ) -> Int { 0 }

    func audioDeviceModule(
        _: RTCAudioDeviceModule,
        willStartEngine _: AVAudioEngine,
        isPlayoutEnabled _: Bool,
        isRecordingEnabled _: Bool
    ) -> Int { 0 }

    func audioDeviceModule(
        _: RTCAudioDeviceModule,
        didStopEngine _: AVAudioEngine,
        isPlayoutEnabled _: Bool,
        isRecordingEnabled _: Bool
    ) -> Int { 0 }

    func audioDeviceModule(
        _: RTCAudioDeviceModule,
        didDisableEngine _: AVAudioEngine,
        isPlayoutEnabled _: Bool,
        isRecordingEnabled _: Bool
    ) -> Int { 0 }

    func audioDeviceModule(_: RTCAudioDeviceModule, willReleaseEngine _: AVAudioEngine) -> Int {
        sourceNode = nil
        return 0
    }
}

/// Render-thread-owned scratch storage. The fixed upper bound avoids allocation
/// in the audio callback; oversized quanta are silenced defensively.
private nonisolated final class LocalCutAudioSourceRenderer: @unchecked Sendable {
    private static let maximumFramesPerRender = 8_192

    private let ring: RingBuffer
    private let channels: Int
    private var scratch: [Float]

    init(ring: RingBuffer, channels: Int) {
        self.ring = ring
        self.channels = channels
        scratch = [Float](
            repeating: 0,
            count: Self.maximumFramesPerRender * channels)
    }

    func render(
        frameCount: AVAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frames = Int(frameCount)
        guard frames <= Self.maximumFramesPerRender else {
            zero(outputData)
            return kAudio_ParamError
        }

        let requestedSamples = frames * channels
        guard requestedSamples > 0 else { return noErr }
        let copied = ring.read(into: &scratch, count: requestedSamples)
        if copied < requestedSamples {
            for index in copied..<requestedSamples {
                scratch[index] = 0
            }
        }

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        if buffers.count == 1 {
            guard let destination = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudio_ParamError
            }
            scratch.withUnsafeBufferPointer { samples in
                destination.update(from: samples.baseAddress!, count: requestedSamples)
            }
            buffers[0].mDataByteSize = UInt32(requestedSamples * MemoryLayout<Float>.size)
            return noErr
        }

        guard buffers.count >= channels else {
            zero(outputData)
            return kAudio_ParamError
        }
        for channel in 0..<channels {
            guard let destination = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else {
                zero(outputData)
                return kAudio_ParamError
            }
            for frame in 0..<frames {
                destination[frame] = scratch[frame * channels + channel]
            }
            buffers[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        }
        return noErr
    }

    private func zero(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}
