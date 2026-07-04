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
    nonisolated(unsafe) private var ringBuffer: RingBuffer?
    private var captureThread: Thread?
    private let stopFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    #if canImport(WebRTC)
    nonisolated(unsafe) private var adm: LocalCutAudioDeviceModule?
    #endif

    #if !canImport(WebRTC)
    nonisolated(unsafe) private(set) var latestBuffer: [Float]?
    nonisolated(unsafe) private(set) var latestSampleRate: Double = 0
    nonisolated(unsafe) private(set) var latestChannels: Int = 0
    #endif

    init() {}

    func start(sampleRate: Double, channels: Int) {
        guard !isRunning else { return }
        self.sampleRate = sampleRate
        self.channels = channels
        self.isRunning = true
        let frameSize = Int(sampleRate * Self.frameDurationSeconds) * channels
        ringBuffer = RingBuffer(capacity: frameSize * 10)
        stopFlag.withLock { $0 = false }
        #if canImport(WebRTC)
        adm = LocalCutAudioDeviceModule(sampleRate: sampleRate, channels: channels)
        #endif
        startCaptureThread(frameSize: frameSize)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopFlag.withLock { $0 = true }
        captureThread?.cancel()
        captureThread = nil
        ringBuffer = nil
        #if canImport(WebRTC)
        adm = nil
        #endif
    }

    nonisolated func pushSamples(_ buffer: [Float], sampleRate: Double, channels: Int) {
        guard let ring = ringBuffer else { return }
        ring.write(buffer)
        #if !canImport(WebRTC)
        latestBuffer = buffer
        latestSampleRate = sampleRate
        latestChannels = channels
        #endif
    }

    private func startCaptureThread(frameSize: Int) {
        let stopFlag = stopFlag
        let ring = ringBuffer
        #if canImport(WebRTC)
        let admRef = adm
        #endif
        let thread = Thread {
            var frameBuffer = [Float](repeating: 0, count: frameSize)
            while true {
                if stopFlag.withLock({ $0 }) { break }
                Thread.sleep(forTimeInterval: Self.frameDurationSeconds)
                guard let ring else { break }
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
