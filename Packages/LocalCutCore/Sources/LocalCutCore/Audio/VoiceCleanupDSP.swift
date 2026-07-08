import Foundation
import Accelerate

public struct VoiceCleanupProcessorState: Sendable {
    public var gateGain: Float
    public var compressorGain: Float
    public var limiterGain: Float

    public init(gateGain: Float = 1, compressorGain: Float = 1, limiterGain: Float = 1) {
        self.gateGain = gateGain
        self.compressorGain = compressorGain
        self.limiterGain = limiterGain
    }
}

public struct LoudnessAnalysisResult: Hashable, Sendable {
    public var measuredLUFS: Float
    public var targetLUFS: Float
    public var gainDB: Float
    public var durationSeconds: Double
    public var note: String?

    public init(measuredLUFS: Float,
                targetLUFS: Float,
                gainDB: Float,
                durationSeconds: Double,
                note: String? = nil) {
        self.measuredLUFS = measuredLUFS
        self.targetLUFS = targetLUFS
        self.gainDB = gainDB
        self.durationSeconds = durationSeconds
        self.note = note
    }
}

public struct VoiceCleanupInsertBypassRamp: Hashable, Sendable {
    public var denoiserStartBypass: Float
    public var denoiserTargetBypass: Float
    public var gateStartBypass: Float
    public var gateTargetBypass: Float
    public var compressorStartBypass: Float
    public var compressorTargetBypass: Float
    public var limiterStartBypass: Float
    public var limiterTargetBypass: Float
    public var rampFrames: Int

    public init(denoiserStartBypass: Float,
                denoiserTargetBypass: Float,
                gateStartBypass: Float,
                gateTargetBypass: Float,
                compressorStartBypass: Float,
                compressorTargetBypass: Float,
                limiterStartBypass: Float,
                limiterTargetBypass: Float,
                rampFrames: Int) {
        self.denoiserStartBypass = denoiserStartBypass
        self.denoiserTargetBypass = denoiserTargetBypass
        self.gateStartBypass = gateStartBypass
        self.gateTargetBypass = gateTargetBypass
        self.compressorStartBypass = compressorStartBypass
        self.compressorTargetBypass = compressorTargetBypass
        self.limiterStartBypass = limiterStartBypass
        self.limiterTargetBypass = limiterTargetBypass
        self.rampFrames = max(1, rampFrames)
    }
}

public enum VoiceCleanupDSP {
    public static func linearGain(fromDB db: Float) -> Float {
        pow(10, db / 20)
    }

    public static func decibels(fromLinear linear: Float) -> Float {
        guard linear > 0 else { return -120 }
        return 20 * log10(linear)
    }

    public static func normalisationGain(measuredLUFS: Float, targetLUFS: Float) -> Float {
        guard measuredLUFS.isFinite, targetLUFS.isFinite else { return 0 }
        return max(-30, min(30, targetLUFS - measuredLUFS))
    }

    public static func processInterleaved(_ samples: inout [Float],
                                          channels: Int,
                                          sampleRate: Double,
                                          settings: VoiceCleanupSettings,
                                          state: inout VoiceCleanupProcessorState) {
        guard channels > 0, !samples.isEmpty else { return }
        var clamped = settings
        clamped.clamp()

        if !clamped.denoiser.bypass {
            applyDenoiser(to: &samples, channels: channels, settings: clamped.denoiser)
        }
        if !clamped.gate.bypass {
            applyGate(to: &samples, channels: channels, sampleRate: sampleRate,
                      settings: clamped.gate, gain: &state.gateGain)
        }
        if !clamped.compressor.bypass {
            applyCompressor(to: &samples, channels: channels, sampleRate: sampleRate,
                            settings: clamped.compressor, gain: &state.compressorGain)
        }
        if clamped.loudness.enabled, abs(clamped.loudness.appliedGainDB) > 0.0001 {
            var gain = linearGain(fromDB: clamped.loudness.appliedGainDB)
            vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))
        }
        if !clamped.limiter.bypass {
            applyLimiter(to: &samples, channels: channels, sampleRate: sampleRate,
                         settings: clamped.limiter, gain: &state.limiterGain)
        }
    }

    public static func processInterleaved(_ samples: inout [Float],
                                          channels: Int,
                                          sampleRate: Double,
                                          settings: VoiceCleanupSettings,
                                          state: inout VoiceCleanupProcessorState,
                                          bypassRamp: VoiceCleanupInsertBypassRamp) {
        guard channels > 0, !samples.isEmpty else { return }
        var clamped = settings
        clamped.clamp()

        applyRampedStage(
            to: &samples,
            channels: channels,
            startBypass: bypassRamp.denoiserStartBypass,
            targetBypass: bypassRamp.denoiserTargetBypass,
            rampFrames: bypassRamp.rampFrames
        ) { stageSamples in
            applyDenoiser(to: &stageSamples, channels: channels, settings: clamped.denoiser)
        }

        applyRampedStage(
            to: &samples,
            channels: channels,
            startBypass: bypassRamp.gateStartBypass,
            targetBypass: bypassRamp.gateTargetBypass,
            rampFrames: bypassRamp.rampFrames
        ) { stageSamples in
            applyGate(to: &stageSamples, channels: channels, sampleRate: sampleRate,
                      settings: clamped.gate, gain: &state.gateGain)
        }

        applyRampedStage(
            to: &samples,
            channels: channels,
            startBypass: bypassRamp.compressorStartBypass,
            targetBypass: bypassRamp.compressorTargetBypass,
            rampFrames: bypassRamp.rampFrames
        ) { stageSamples in
            applyCompressor(to: &stageSamples, channels: channels, sampleRate: sampleRate,
                            settings: clamped.compressor, gain: &state.compressorGain)
        }

        if clamped.loudness.enabled, abs(clamped.loudness.appliedGainDB) > 0.0001 {
            var gain = linearGain(fromDB: clamped.loudness.appliedGainDB)
            vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))
        }

        applyRampedStage(
            to: &samples,
            channels: channels,
            startBypass: bypassRamp.limiterStartBypass,
            targetBypass: bypassRamp.limiterTargetBypass,
            rampFrames: bypassRamp.rampFrames
        ) { stageSamples in
            applyLimiter(to: &stageSamples, channels: channels, sampleRate: sampleRate,
                         settings: clamped.limiter, gain: &state.limiterGain)
        }
    }

    public static func measureIntegratedLoudness(interleaved samples: [Float],
                                                 channels: Int,
                                                 sampleRate: Double,
                                                 targetLUFS: Float) -> LoudnessAnalysisResult {
        let duration = channels > 0 ? Double(samples.count / channels) / sampleRate : 0
        guard duration >= 3 else {
            return LoudnessAnalysisResult(
                measuredLUFS: -.infinity,
                targetLUFS: targetLUFS,
                gainDB: 0,
                durationSeconds: duration,
                note: "Normalisation skipped: selection is shorter than 3 seconds.")
        }
        guard sampleRate == 48_000 else {
            return LoudnessAnalysisResult(
                measuredLUFS: -.infinity,
                targetLUFS: targetLUFS,
                gainDB: 0,
                durationSeconds: duration,
                note: "Normalisation skipped: only 48 kHz audio is currently supported.")
        }

        var analyser = EBUR128LoudnessAnalyser(sampleRate: sampleRate, channels: channels)
        analyser.feedInterleaved(samples, channels: channels)
        let measured = analyser.integratedLoudness()
        let gain = normalisationGain(measuredLUFS: measured, targetLUFS: targetLUFS)
        return LoudnessAnalysisResult(
            measuredLUFS: measured,
            targetLUFS: targetLUFS,
            gainDB: gain,
            durationSeconds: duration)
    }

    private static func applyDenoiser(to samples: inout [Float],
                                      channels: Int,
                                      settings: DenoiserSettings) {
        guard !samples.isEmpty, channels > 0 else { return }
        let floor = linearGain(fromDB: settings.noiseFloorDB)
        let knee = max(floor * 6, 0.000_001)

        // Process per frame and derive a single reduction from the loudest
        // channel so both channels are attenuated together. Linking the
        // channels preserves the stereo image (independent per-sample gains
        // cause image shifting / fluttering) and avoids the per-buffer heap
        // allocation a separate magnitudes array would need (Gemini review).
        var frame = 0
        while frame < samples.count {
            let end = min(frame + channels, samples.count)
            var magnitude: Float = 0
            for i in frame..<end { magnitude = max(magnitude, abs(samples[i])) }

            let proximity = 1 - min(1, magnitude / knee)
            let reduction = settings.reduction * proximity
            let gain = max(0, 1 - reduction)
            for i in frame..<end { samples[i] *= gain }
            frame += channels
        }
    }

    private static func applyGate(to samples: inout [Float],
                                  channels: Int,
                                  sampleRate: Double,
                                  settings: GateSettings,
                                  gain: inout Float) {
        let threshold = linearGain(fromDB: settings.thresholdDB)
        let closedGain = linearGain(fromDB: settings.rangeDB)
        let detectorFrameRate = detectorFrameRate(sampleRate: sampleRate, channels: channels)
        let attack = smoothingCoefficient(milliseconds: settings.attackMS, sampleRate: detectorFrameRate)
        let release = smoothingCoefficient(milliseconds: settings.releaseMS, sampleRate: detectorFrameRate)

        var frame = 0
        while frame < samples.count {
            let end = min(frame + channels, samples.count)
            var magnitude: Float = 0
            for i in frame..<end { magnitude = max(magnitude, abs(samples[i])) }

            let target = magnitude >= threshold ? Float(1) : closedGain
            let coefficient = target > gain ? attack : release
            gain += (target - gain) * coefficient
            for i in frame..<end { samples[i] *= gain }
            frame += channels
        }
    }

    private static func applyCompressor(to samples: inout [Float],
                                        channels: Int,
                                        sampleRate: Double,
                                        settings: CompressorSettings,
                                        gain: inout Float) {
        let detectorFrameRate = detectorFrameRate(sampleRate: sampleRate, channels: channels)
        let attack = smoothingCoefficient(milliseconds: settings.attackMS, sampleRate: detectorFrameRate)
        let release = smoothingCoefficient(milliseconds: settings.releaseMS, sampleRate: detectorFrameRate)
        let makeupGain = linearGain(fromDB: settings.makeupGainDB)

        var frame = 0
        while frame < samples.count {
            let end = min(frame + channels, samples.count)
            var magnitude: Float = 0
            for i in frame..<end { magnitude = max(magnitude, abs(samples[i])) }

            let levelDB = decibels(fromLinear: magnitude)
            var targetGR: Float = 1
            if levelDB > settings.thresholdDB {
                let compressed = settings.thresholdDB + (levelDB - settings.thresholdDB) / settings.ratio
                targetGR = linearGain(fromDB: compressed - levelDB)
            }

            // Smooth only the gain reduction (starts at 1.0); apply the static
            // makeup gain afterwards so there is no start-of-track fade-in.
            let coefficient = targetGR < gain ? attack : release
            gain += (targetGR - gain) * coefficient
            let totalGain = gain * makeupGain
            for i in frame..<end { samples[i] *= totalGain }
            frame += channels
        }
    }

    private static func applyLimiter(to samples: inout [Float],
                                     channels: Int,
                                     sampleRate: Double,
                                     settings: LimiterSettings,
                                     gain: inout Float) {
        let ceiling = linearGain(fromDB: settings.ceilingDB)
        let release = smoothingCoefficient(milliseconds: settings.releaseMS, sampleRate: sampleRate)
        var frame = 0
        while frame < samples.count {
            let end = min(frame + channels, samples.count)
            var magnitude: Float = 0
            for i in frame..<end { magnitude = max(magnitude, abs(samples[i])) }

            let targetGain = magnitude > ceiling && magnitude > 0
                ? min(1, ceiling / magnitude)
                : Float(1)
            if targetGain < gain {
                gain = targetGain
            } else {
                gain += (targetGain - gain) * release
            }

            for i in frame..<end {
                let limited = samples[i] * gain
                samples[i] = max(-ceiling, min(ceiling, limited))
            }
            frame += channels
        }
    }

    private static func applyRampedStage(to samples: inout [Float],
                                         channels: Int,
                                         startBypass: Float,
                                         targetBypass: Float,
                                         rampFrames: Int,
                                         process: (inout [Float]) -> Void) {
        let startBypass = clampedBypass(startBypass)
        let targetBypass = clampedBypass(targetBypass)
        guard max(1 - startBypass, 1 - targetBypass) > 0.000_1 else { return }

        let dry = samples
        process(&samples)
        blendRampedStage(output: &samples,
                         dry: dry,
                         channels: channels,
                         startBypass: startBypass,
                         targetBypass: targetBypass,
                         rampFrames: rampFrames)
    }

    private static func blendRampedStage(output: inout [Float],
                                         dry: [Float],
                                         channels: Int,
                                         startBypass: Float,
                                         targetBypass: Float,
                                         rampFrames: Int) {
        let frameCount = output.count / channels
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let bypass = rampedBypass(start: startBypass,
                                      target: targetBypass,
                                      frameOffset: frame,
                                      rampFrames: rampFrames)
            let activeMix = 1 - bypass
            let dryMix = bypass
            let base = frame * channels
            for channel in 0..<channels {
                let index = base + channel
                output[index] = dry[index] * dryMix + output[index] * activeMix
            }
        }
    }

    public static func rampedBypass(start: Float,
                                    target: Float,
                                    frameOffset: Int,
                                    rampFrames: Int) -> Float {
        let start = clampedBypass(start)
        let target = clampedBypass(target)
        guard start != target else { return target }
        let delta = Float(max(0, frameOffset)) / Float(max(1, rampFrames))
        if target > start {
            return min(target, start + delta)
        }
        return max(target, start - delta)
    }

    private static func clampedBypass(_ value: Float) -> Float {
        max(0, min(1, value))
    }

    private static func detectorFrameRate(sampleRate: Double, channels: Int) -> Double {
        // The detector advances once per interleaved frame (one set of all
        // channels). The configured attack/release times are in terms of audio
        // frames, not samples, so the frame rate equals the sample rate
        // regardless of channel count.
        sampleRate
    }

    private static func smoothingCoefficient(milliseconds: Float, sampleRate: Double) -> Float {
        let samples = max(1, Double(milliseconds) * sampleRate / 1000)
        return Float(1 - exp(-1 / samples))
    }
}

public struct EBUR128LoudnessAnalyser: Sendable {
    private let sampleRate: Double
    private let channels: Int
    private var channelStates: [KWeightingFilter]
    private var ringBuffers: [[Float]]
    private var ringIndex = 0
    private var primedSamples = 0
    private var windowEnergies: [Float] = []
    private var samplesSinceLastWindow = 0
    private var hasFirstWindow = false

    public init(sampleRate: Double = 48_000, channels: Int = 2) {
        // The K-weighting biquad coefficients below are precomputed for 48 kHz.
        // Feeding any other rate would silently produce wrong loudness; callers
        // must guard before constructing this analyser (see
        // `measureIntegratedLoudness` for the upstream guard).
        assert(sampleRate == 48_000,
               "EBUR128LoudnessAnalyser currently only supports a 48 kHz sample rate.")
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.channelStates = Array(repeating: KWeightingFilter(), count: max(1, channels))
        let windowLength = max(1, Int((sampleRate * 0.4).rounded()))
        self.ringBuffers = Array(repeating: Array(repeating: 0, count: windowLength),
                                 count: max(1, channels))
    }

    public mutating func feedInterleaved(_ samples: [Float], channels inputChannels: Int) {
        let inputChannels = max(1, inputChannels)
        let hopLength = max(1, Int((sampleRate * 0.1).rounded()))
        let frameCount = samples.count / inputChannels
        var cursor = 0
        while cursor < frameCount {
            let frames = min(hopLength, frameCount - cursor)
            var filteredChannels: [[Float]] = []
            for channel in 0..<channels {
                var mono = Array(repeating: Float(0), count: frames)
                let sourceChannel = min(channel, inputChannels - 1)
                for frame in 0..<frames {
                    mono[frame] = samples[(cursor + frame) * inputChannels + sourceChannel]
                }
                filteredChannels.append(channelStates[channel].process(mono))
            }
            appendWindow(filteredChannels, frames: frames)
            cursor += frames
        }
    }

    public mutating func reset() {
        channelStates = Array(repeating: KWeightingFilter(), count: channels)
        let windowLength = max(1, Int((sampleRate * 0.4).rounded()))
        ringBuffers = Array(repeating: Array(repeating: 0, count: windowLength),
                            count: channels)
        ringIndex = 0
        primedSamples = 0
        windowEnergies.removeAll()
        samplesSinceLastWindow = 0
        hasFirstWindow = false
    }

    public func integratedLoudness() -> Float {
        let absolute = windowEnergies.filter {
            loudness(energy: $0) >= -70
        }
        guard !absolute.isEmpty else { return -.infinity }

        let ungatedEnergy = absolute.reduce(Float(0), +) / Float(absolute.count)
        let ungated = loudness(energy: ungatedEnergy)
        let relativeThreshold = ungated - 10
        let gated = absolute.filter { loudness(energy: $0) >= relativeThreshold }
        guard !gated.isEmpty else { return -.infinity }

        let finalEnergy = gated.reduce(Float(0), +) / Float(gated.count)
        return loudness(energy: finalEnergy)
    }

    private mutating func appendWindow(_ filteredChannels: [[Float]], frames: Int) {
        guard frames > 0, let windowLength = ringBuffers.first?.count else { return }
        // EBU R128 requires one overlapping 400 ms energy point every 100 ms,
        // independent of the incoming buffer size. Count samples between windows
        // so the density stays at 10 points/second regardless of chunking.
        let hopLength = max(1, Int((sampleRate * 0.1).rounded()))
        for frame in 0..<frames {
            for channel in 0..<channels {
                ringBuffers[channel][ringIndex] = filteredChannels[channel][frame]
            }
            ringIndex = (ringIndex + 1) % windowLength
            primedSamples = min(windowLength, primedSamples + 1)

            guard primedSamples == windowLength else { continue }
            if !hasFirstWindow {
                hasFirstWindow = true
                samplesSinceLastWindow = 0
                appendCurrentWindowEnergy(windowLength: windowLength)
            } else {
                samplesSinceLastWindow += 1
                if samplesSinceLastWindow >= hopLength {
                    samplesSinceLastWindow = 0
                    appendCurrentWindowEnergy(windowLength: windowLength)
                }
            }
        }
    }

    private mutating func appendCurrentWindowEnergy(windowLength: Int) {
        var energy: Float = 0
        for channel in 0..<channels {
            var meanSquare: Float = 0
            vDSP_measqv(ringBuffers[channel], 1, &meanSquare, vDSP_Length(windowLength))
            energy += meanSquare
        }
        windowEnergies.append(max(energy, Float.leastNonzeroMagnitude))
    }

    private func loudness(energy: Float) -> Float {
        guard energy > 0 else { return -.infinity }
        return -0.691 + 10 * log10(energy)
    }
}

private struct KWeightingFilter: Sendable {
    private var stage1 = BiquadState()
    private var stage2 = BiquadState()

    mutating func process(_ input: [Float]) -> [Float] {
        let pre = stage1.process(
            input,
            b0: 1.535_124_9,
            b1: -2.691_696_2,
            b2: 1.198_392_9,
            a1: -1.690_659_3,
            a2: 0.732_480_76)
        return stage2.process(
            pre,
            b0: 1,
            b1: -2,
            b2: 1,
            a1: -1.990_047_5,
            a2: 0.990_072_25)
    }
}

private struct BiquadState: Sendable {
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    mutating func process(_ input: [Float],
                          b0: Float,
                          b1: Float,
                          b2: Float,
                          a1: Float,
                          a2: Float) -> [Float] {
        let output = Array<Float>(unsafeUninitializedCapacity: input.count) { buffer, initializedCount in
            for index in input.indices {
                let x = input[index]
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                buffer[index] = y
                x2 = x1
                x1 = x
                y2 = y1
                y1 = y
            }
            initializedCount = input.count
        }
        return output
    }
}
