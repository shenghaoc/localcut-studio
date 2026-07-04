import Foundation
import os

#if canImport(WebRTC)
import WebRTC
#endif

actor AudioPublishBridge {
    private static let frameDurationSeconds: Double = 0.01
    private var isRunning = false
    private var sampleRate: Double = 48_000
    private var channels: Int = 2
    private var captureThread: Thread?
    private let stopFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    #if canImport(WebRTC)
    private var adm: LocalCutAudioDeviceModule?
    #endif

    private struct SharedState {
        var ringBuffer: RingBuffer?
        #if !canImport(WebRTC)
        var latestBuffer: [Float]?
        var latestSampleRate: Double = 0
        var latestChannels: Int = 0
        #endif
    }
    private let sharedState = OSAllocatedUnfairLock(initialState: SharedState())

    #if !canImport(WebRTC)
    nonisolated var latestBuffer: [Float]? { sharedState.withLock { $0.latestBuffer } }
    nonisolated var latestSampleRate: Double { sharedState.withLock { $0.latestSampleRate } }
    nonisolated var latestChannels: Int { sharedState.withLock { $0.latestChannels } }
    #endif

    init() {}

    func start(sampleRate: Double, channels: Int) {
        guard !isRunning else { return }
        self.sampleRate = sampleRate
        self.channels = channels
        self.isRunning = true
        let frameSize = Int(sampleRate * Self.frameDurationSeconds) * channels
        let newRing = RingBuffer(capacity: frameSize * 10)
        sharedState.withLock { $0.ringBuffer = newRing }
        stopFlag.withLock { $0 = false }
        #if canImport(WebRTC)
        adm = LocalCutAudioDeviceModule(sampleRate: sampleRate, channels: channels)
        #endif
        startCaptureThread(frameSize: frameSize, ring: newRing)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopFlag.withLock { $0 = true }
        captureThread?.cancel()
        captureThread = nil
        sharedState.withLock { $0.ringBuffer = nil }
        #if canImport(WebRTC)
        adm = nil
        #endif
    }

    nonisolated func pushSamples(_ buffer: [Float], sampleRate: Double, channels: Int) {
        sharedState.withLock { s in
            guard let ring = s.ringBuffer else { return }
            ring.write(buffer)
            #if !canImport(WebRTC)
            s.latestBuffer = buffer
            s.latestSampleRate = sampleRate
            s.latestChannels = channels
            #endif
        }
    }

    private func startCaptureThread(frameSize: Int, ring: RingBuffer) {
        let stopFlag = stopFlag
        #if canImport(WebRTC)
        let admRef = adm
        #endif
        let thread = Thread {
            var frameBuffer = [Float](repeating: 0, count: frameSize)
            while true {
                if stopFlag.withLock({ $0 }) { break }
                Thread.sleep(forTimeInterval: Self.frameDurationSeconds)
                let readSamples = ring.read(count: frameSize)
                for i in 0..<readSamples.count { frameBuffer[i] = readSamples[i] }
                for i in readSamples.count..<frameSize { frameBuffer[i] = 0 }
                #if canImport(WebRTC)
                admRef?.deliverCaptureFrame(frameBuffer)
                #endif
            }
        }
        thread.name = "com.localcut.whip-audio-capture"
        thread.qualityOfService = .userInitiated
        captureThread = thread
        thread.start()
    }
}

#if canImport(WebRTC)
final class LocalCutAudioDeviceModule: @unchecked Sendable {
    let sampleRate: Double
    let channels: Int
    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
    func deliverCaptureFrame(_ samples: [Float]) {
        // TODO: Forward to C++ ADM bridge when linked.
    }
}
#endif
