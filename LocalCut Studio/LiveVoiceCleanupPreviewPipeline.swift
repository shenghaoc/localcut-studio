import Foundation
import AVFoundation
import CoreMedia
import os
import LocalCutCore

nonisolated final class LiveVoiceCleanupSettingsStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<VoiceCleanupSettings>(
        initialState: VoiceCleanupSettings())

    func update(_ settings: VoiceCleanupSettings) {
        var clamped = settings
        clamped.clamp()
        let stored = clamped
        lock.withLock { $0 = stored }
    }

    func read() -> VoiceCleanupSettings {
        lock.withLock { $0 }
    }
}

nonisolated final class LiveQueuedFrameCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    func reset() {
        lock.withLock { $0 = 0 }
    }

    func add(_ frames: Int) {
        lock.withLock { $0 += max(0, frames) }
    }

    func remove(_ frames: Int) {
        lock.withLock { $0 = max(0, $0 - max(0, frames)) }
    }

    var value: Int {
        lock.withLock { $0 }
    }
}

nonisolated final class LiveGainReductionStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<LiveGainReduction>(
        initialState: LiveGainReduction())

    func update(_ value: LiveGainReduction) {
        lock.withLock { $0 = value }
    }

    func read() -> LiveGainReduction {
        lock.withLock { $0 }
    }
}

struct LiveGainReduction: Sendable, Equatable {
    var denoiserReduction: Float = 0
    var gateReductionDB: Float = 0
    var compressorReductionDB: Float = 0
    var limiterReductionDB: Float = 0
}

nonisolated struct LiveAudioPCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

struct BypassRampState: Sendable {
    var denoiserBypass: Float = 1.0
    var gateBypass: Float = 1.0
    var compressorBypass: Float = 1.0
    var limiterBypass: Float = 1.0

    nonisolated mutating func advance(targetDenoiserBypass: Float,
                                      targetGateBypass: Float,
                                      targetCompressorBypass: Float,
                                      targetLimiterBypass: Float,
                                      frameCount: Int,
                                      rampFrames: Int) {
        denoiserBypass = VoiceCleanupDSP.rampedBypass(
            start: denoiserBypass,
            target: targetDenoiserBypass,
            frameOffset: frameCount,
            rampFrames: rampFrames)
        gateBypass = VoiceCleanupDSP.rampedBypass(
            start: gateBypass,
            target: targetGateBypass,
            frameOffset: frameCount,
            rampFrames: rampFrames)
        compressorBypass = VoiceCleanupDSP.rampedBypass(
            start: compressorBypass,
            target: targetCompressorBypass,
            frameOffset: frameCount,
            rampFrames: rampFrames)
        limiterBypass = VoiceCleanupDSP.rampedBypass(
            start: limiterBypass,
            target: targetLimiterBypass,
            frameOffset: frameCount,
            rampFrames: rampFrames)
    }

    nonisolated mutating func snapshotAndAdvance(settings: VoiceCleanupSettings,
                                                 frameCount: Int,
                                                 rampFrames: Int) -> VoiceCleanupInsertBypassRamp {
        let targetDenoiser: Float = settings.denoiser.bypass ? 1.0 : 0.0
        let targetGate: Float = settings.gate.bypass ? 1.0 : 0.0
        let targetCompressor: Float = settings.compressor.bypass ? 1.0 : 0.0
        let targetLimiter: Float = settings.limiter.bypass ? 1.0 : 0.0
        let snapshot = VoiceCleanupInsertBypassRamp(
            denoiserStartBypass: denoiserBypass,
            denoiserTargetBypass: targetDenoiser,
            gateStartBypass: gateBypass,
            gateTargetBypass: targetGate,
            compressorStartBypass: compressorBypass,
            compressorTargetBypass: targetCompressor,
            limiterStartBypass: limiterBypass,
            limiterTargetBypass: targetLimiter,
            rampFrames: rampFrames)
        advance(targetDenoiserBypass: targetDenoiser,
                targetGateBypass: targetGate,
                targetCompressorBypass: targetCompressor,
                targetLimiterBypass: targetLimiter,
                frameCount: frameCount,
                rampFrames: rampFrames)
        return snapshot
    }
}

enum LiveVoiceCleanupPreviewPipeline {
    nonisolated static let maxQueuedFrames = 16_384

    nonisolated static func decodeProcessAndSchedule(
        composition: AVComposition,
        audioMix: AVAudioMix?,
        startTime: CMTime,
        settingsStore: LiveVoiceCleanupSettingsStore,
        queuedFrames: LiveQueuedFrameCounter,
        gainReductionStore: LiveGainReductionStore,
        scheduleBuffer: (AVAudioPCMBuffer, Int) async -> Void
    ) async throws {
        let audioTracks = composition.tracks(withMediaType: .audio) as [AVAssetTrack]
        guard !audioTracks.isEmpty else { return }

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VoiceCleanupError.readerOutputRejected
        }
        reader.add(output)
        if startTime > .zero {
            reader.timeRange = CMTimeRange(start: startTime, end: composition.duration)
        }
        guard reader.startReading() else {
            throw reader.error ?? VoiceCleanupError.readerStartFailed
        }

        var processorState = VoiceCleanupProcessorState()
        var rampState = BypassRampState()
        while reader.status == .reading {
            try Task.checkCancellation()
            while queuedFrames.value > maxQueuedFrames {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }

            guard let sample = output.copyNextSampleBuffer() else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            guard var block = VoiceCleanupAudioProcessing.floatBlock(from: sample),
                  !block.samples.isEmpty else {
                continue
            }

            let frameCount = block.samples.count / max(1, block.channels)
            while queuedFrames.value + frameCount > maxQueuedFrames {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }

            let settings = settingsStore.read()
            let rampFrames = max(1, Int(0.005 * block.sampleRate))
            let ramp = rampState.snapshotAndAdvance(
                settings: settings,
                frameCount: frameCount,
                rampFrames: rampFrames)
            VoiceCleanupDSP.processInterleaved(
                &block.samples,
                channels: block.channels,
                sampleRate: block.sampleRate,
                settings: settings,
                state: &processorState,
                bypassRamp: ramp)
            gainReductionStore.update(gainReduction(settings: settings, state: processorState))

            guard let pcm = makePCMBuffer(from: block) else { continue }
            await scheduleBuffer(pcm, Int(pcm.frameLength))
        }

        if reader.status == .failed, let error = reader.error {
            throw error
        }
    }

    private nonisolated static func makePCMBuffer(
        from block: VoiceCleanupAudioProcessing.PCMBlock
    ) -> AVAudioPCMBuffer? {
        guard block.channels > 0, !block.samples.isEmpty else { return nil }
        let frameCount = block.samples.count / block.channels
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: block.sampleRate,
            channels: AVAudioChannelCount(block.channels)),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            let base = frame * block.channels
            for channel in 0..<block.channels {
                channelData[channel][frame] = block.samples[base + channel]
            }
        }
        return buffer
    }

    private nonisolated static func gainReduction(
        settings: VoiceCleanupSettings,
        state: VoiceCleanupProcessorState
    ) -> LiveGainReduction {
        LiveGainReduction(
            denoiserReduction: settings.denoiser.bypass ? 0 : settings.denoiser.reduction,
            gateReductionDB: settings.gate.bypass || state.gateGain >= 1
                ? 0
                : VoiceCleanupDSP.decibels(fromLinear: state.gateGain),
            compressorReductionDB: settings.compressor.bypass || state.compressorGain >= 1
                ? 0
                : VoiceCleanupDSP.decibels(fromLinear: state.compressorGain),
            limiterReductionDB: settings.limiter.bypass || state.limiterGain >= 1
                ? 0
                : VoiceCleanupDSP.decibels(fromLinear: state.limiterGain))
    }
}
