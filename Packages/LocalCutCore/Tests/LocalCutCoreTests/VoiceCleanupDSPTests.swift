import Testing
import Foundation
import LocalCutCore

@Test("VoiceCleanupSettings: defaults are fully bypassed")
func voiceCleanupDefaultsAreNoOp() {
    let settings = VoiceCleanupSettings()
    #expect(settings.denoiser.bypass)
    #expect(settings.gate.bypass)
    #expect(settings.compressor.bypass)
    #expect(settings.limiter.bypass)
    #expect(settings.requiresOfflineProcessing == false)
}

@Test("VoiceCleanupSettings: loudness gain requires offline processing")
func loudnessGainRequiresOfflineProcessing() {
    var settings = VoiceCleanupSettings()
    settings.loudness.enabled = true
    settings.loudness.appliedGainDB = 3
    #expect(settings.requiresOfflineProcessing)
}

@Test("VoiceCleanupDSP: limiter clamps samples to ceiling")
func limiterClampsSamples() {
    var settings = VoiceCleanupSettings()
    settings.limiter.bypass = false
    settings.limiter.ceilingDB = -6
    var state = VoiceCleanupProcessorState()
    var samples: [Float] = [0.1, -0.1, 0.9, -0.9]
    VoiceCleanupDSP.processInterleaved(
        &samples,
        channels: 2,
        sampleRate: 48_000,
        settings: settings,
        state: &state)

    let ceiling = VoiceCleanupDSP.linearGain(fromDB: -6)
    #expect(samples.allSatisfy { abs($0) <= ceiling + 0.0001 })
}

@Test("VoiceCleanupDSP: limiter release recovers after overs")
func limiterReleaseRecoversAfterOvers() {
    var settings = VoiceCleanupSettings()
    settings.limiter.bypass = false
    settings.limiter.ceilingDB = -6
    settings.limiter.releaseMS = 50
    var state = VoiceCleanupProcessorState()
    var samples = Array(repeating: Float(1.0), count: 24)
        + Array(repeating: Float(0.1), count: 4_800)

    VoiceCleanupDSP.processInterleaved(
        &samples,
        channels: 1,
        sampleRate: 48_000,
        settings: settings,
        state: &state)

    let ceiling = VoiceCleanupDSP.linearGain(fromDB: -6)
    #expect(abs(samples[0] - ceiling) < 0.0001)
    #expect(samples[24] < 0.1)
    #expect(samples.last ?? 0 > 0.085)
}

@Test("VoiceCleanupDSP: compressor applies makeup gain immediately without fade-in")
func compressorMakeupHasNoStartFadeIn() {
    var settings = VoiceCleanupSettings()
    settings.compressor.bypass = false
    settings.compressor.thresholdDB = -18   // signal stays below threshold (no GR)
    settings.compressor.makeupGainDB = 6     // ~2x linear makeup gain
    var state = VoiceCleanupProcessorState()

    let amplitude: Float = 0.01              // -40 dBFS, comfortably below threshold
    let input = Array(repeating: amplitude, count: 480 * 2)
    var samples = input
    VoiceCleanupDSP.processInterleaved(
        &samples,
        channels: 2,
        sampleRate: 48_000,
        settings: settings,
        state: &state)

    let makeup = VoiceCleanupDSP.linearGain(fromDB: 6)
    let expected = amplitude * makeup
    // The very first frame is already at full makeup gain — no slow ramp up
    // from unity that the old combined-gain smoothing produced.
    #expect(abs(samples[0] - expected) < 1e-5)
    // Below threshold there is no gain reduction, so every sample equals
    // input × makeup with no envelope drift.
    #expect(samples.allSatisfy { abs($0 - expected) < 1e-5 })
}

@Test("EBUR128: stereo 1 kHz reference tone lands at expected LUFS")
func ebuR128ReferenceToneAbsoluteLoudness() {
    let sampleRate = 48_000.0
    let channels = 2
    let frameCount = Int(sampleRate * 5)
    let amplitude = Float(pow(10.0, -20.0 / 20.0))
    var samples: [Float] = []
    samples.reserveCapacity(frameCount * channels)
    for frame in 0..<frameCount {
        let value = amplitude * Float(sin(2.0 * .pi * 1000.0 * Double(frame) / sampleRate))
        samples.append(value)
        samples.append(value)
    }

    let result = VoiceCleanupDSP.measureIntegratedLoudness(
        interleaved: samples,
        channels: channels,
        sampleRate: sampleRate,
        targetLUFS: -14)

    #expect(abs(result.measuredLUFS - (-20.0)) < 0.15)
}

@Test("VoiceCleanupDSP: gate envelope timing is independent of channel count")
func gateEnvelopeUsesAudioFrameRate() {
    var settings = VoiceCleanupSettings()
    settings.gate.bypass = false
    settings.gate.thresholdDB = 0
    settings.gate.rangeDB = -40
    settings.gate.releaseMS = 10
    let frames = 480
    let sampleRate = 48_000.0
    let amplitude: Float = 0.01

    var mono = Array(repeating: amplitude, count: frames)
    var stereo: [Float] = []
    stereo.reserveCapacity(frames * 2)
    for _ in 0..<frames {
        stereo.append(amplitude)
        stereo.append(amplitude)
    }

    var monoState = VoiceCleanupProcessorState()
    var stereoState = VoiceCleanupProcessorState()
    VoiceCleanupDSP.processInterleaved(
        &mono,
        channels: 1,
        sampleRate: sampleRate,
        settings: settings,
        state: &monoState)
    VoiceCleanupDSP.processInterleaved(
        &stereo,
        channels: 2,
        sampleRate: sampleRate,
        settings: settings,
        state: &stereoState)

    for frame in [0, 1, 120, 240, 479] {
        #expect(abs(mono[frame] - stereo[frame * 2]) < 1e-6)
        #expect(abs(mono[frame] - stereo[frame * 2 + 1]) < 1e-6)
    }
}

@Test("VoiceCleanupDSP: compressor envelope timing is independent of channel count")
func compressorEnvelopeUsesAudioFrameRate() {
    var settings = VoiceCleanupSettings()
    settings.compressor.bypass = false
    settings.compressor.thresholdDB = -40
    settings.compressor.ratio = 4
    settings.compressor.attackMS = 10
    settings.compressor.makeupGainDB = 0
    let frames = 480
    let sampleRate = 48_000.0
    let amplitude: Float = 0.5

    var mono = Array(repeating: amplitude, count: frames)
    var stereo: [Float] = []
    stereo.reserveCapacity(frames * 2)
    for _ in 0..<frames {
        stereo.append(amplitude)
        stereo.append(amplitude)
    }

    var monoState = VoiceCleanupProcessorState()
    var stereoState = VoiceCleanupProcessorState()
    VoiceCleanupDSP.processInterleaved(
        &mono,
        channels: 1,
        sampleRate: sampleRate,
        settings: settings,
        state: &monoState)
    VoiceCleanupDSP.processInterleaved(
        &stereo,
        channels: 2,
        sampleRate: sampleRate,
        settings: settings,
        state: &stereoState)

    for frame in [0, 1, 120, 240, 479] {
        #expect(abs(mono[frame] - stereo[frame * 2]) < 1e-6)
        #expect(abs(mono[frame] - stereo[frame * 2 + 1]) < 1e-6)
    }
}

@Test("VoiceCleanupDSP: ramped bypass applies each insert independently")
func rampedBypassDoesNotDiluteActiveInsert() {
    var settings = VoiceCleanupSettings()
    settings.limiter.ceilingDB = -6
    var samples: [Float] = [0.9, -0.9, 0.9, -0.9]
    var state = VoiceCleanupProcessorState()
    let ramp = VoiceCleanupInsertBypassRamp(
        denoiserStartBypass: 1,
        denoiserTargetBypass: 1,
        gateStartBypass: 1,
        gateTargetBypass: 1,
        compressorStartBypass: 1,
        compressorTargetBypass: 1,
        limiterStartBypass: 0,
        limiterTargetBypass: 0,
        rampFrames: 1)

    VoiceCleanupDSP.processInterleaved(
        &samples,
        channels: 2,
        sampleRate: 48_000,
        settings: settings,
        state: &state,
        bypassRamp: ramp)

    let ceiling = VoiceCleanupDSP.linearGain(fromDB: -6)
    #expect(samples.allSatisfy { abs($0) <= ceiling + 0.0001 })
}

@Test("VoiceCleanupDSP: ramped bypass interpolates within the buffer")
func rampedBypassInterpolatesWithinBuffer() {
    var settings = VoiceCleanupSettings()
    settings.limiter.ceilingDB = -6
    var samples: [Float] = [
        0.9, 0.9,
        0.9, 0.9,
        0.9, 0.9,
    ]
    var state = VoiceCleanupProcessorState()
    let ramp = VoiceCleanupInsertBypassRamp(
        denoiserStartBypass: 1,
        denoiserTargetBypass: 1,
        gateStartBypass: 1,
        gateTargetBypass: 1,
        compressorStartBypass: 1,
        compressorTargetBypass: 1,
        limiterStartBypass: 1,
        limiterTargetBypass: 0,
        rampFrames: 2)

    VoiceCleanupDSP.processInterleaved(
        &samples,
        channels: 2,
        sampleRate: 48_000,
        settings: settings,
        state: &state,
        bypassRamp: ramp)

    let ceiling = VoiceCleanupDSP.linearGain(fromDB: -6)
    #expect(abs(samples[0] - 0.9) < 0.0001)
    #expect(samples[2] < 0.9)
    #expect(abs(samples[4] - ceiling) < 0.0001)
}

@Test("Loudness: changing the target re-derives applied gain from the measurement")
func loudnessTargetRederivesAppliedGain() {
    var loudness = LoudnessNormalisationSettings()
    loudness.preset = .custom
    loudness.customTargetLUFS = -14
    loudness.measuredLUFS = -20
    loudness.refreshAppliedGainFromMeasurement()
    #expect(abs(loudness.appliedGainDB - 6) < 0.001)   // -14 − (-20) = +6
    #expect(loudness.enabled)

    loudness.customTargetLUFS = -23
    loudness.refreshAppliedGainFromMeasurement()
    #expect(abs(loudness.appliedGainDB - (-3)) < 0.001) // -23 − (-20) = -3
    #expect(loudness.enabled)
}

@Test("Loudness: a manually dialled gain is preserved when nothing was measured")
func loudnessManualGainPreservedWithoutMeasurement() {
    var loudness = LoudnessNormalisationSettings()
    loudness.measuredLUFS = nil
    loudness.appliedGainDB = 4
    loudness.enabled = true
    loudness.refreshAppliedGainFromMeasurement()
    #expect(loudness.appliedGainDB == 4)
    #expect(loudness.enabled)
}

@Test("VoiceCleanupDSP: ranges shorter than 3 seconds skip normalisation")
func shortLoudnessRangeSkipsNormalisation() {
    let samples = Array(repeating: Float(0.1), count: 2 * 48_000 * 2)
    let result = VoiceCleanupDSP.measureIntegratedLoudness(
        interleaved: samples,
        channels: 2,
        sampleRate: 48_000,
        targetLUFS: -14)

    #expect(result.measuredLUFS == -.infinity)
    #expect(result.gainDB == 0)
    #expect(result.note != nil)
}

@Test("EBUR128: sine measurement is finite and gain equals target minus measured")
func loudnessMeasurementProducesExpectedGain() {
    let sampleRate = 48_000.0
    let seconds = 4.0
    let frames = Int(sampleRate * seconds)
    let frequency = 997.0
    let amplitude: Float = 0.1
    var samples: [Float] = []
    samples.reserveCapacity(frames * 2)
    for frame in 0..<frames {
        let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
        samples.append(value)
        samples.append(value)
    }

    let result = VoiceCleanupDSP.measureIntegratedLoudness(
        interleaved: samples,
        channels: 2,
        sampleRate: sampleRate,
        targetLUFS: -14)

    #expect(result.measuredLUFS.isFinite)
    #expect(abs(result.gainDB - (-14 - result.measuredLUFS)) < 0.001)
}

@Test("VoiceCleanupDSP: zero sample rate does not crash")
func zeroSampleRateDoesNotCrash() {
    var settings = VoiceCleanupSettings()
    settings.limiter.bypass = false
    var state = VoiceCleanupProcessorState()
    var samples: [Float] = [0.1, -0.1, 0.2, -0.2]
    // Zero sample rate should not cause a crash or undefined behavior.
    // The DSP functions use sampleRate for timing calculations; a zero
    // value would produce infinite/NaN durations but should not trap.
    VoiceCleanupDSP.processInterleaved(
        &samples,
        channels: 2,
        sampleRate: 0,
        settings: settings,
        state: &state)
    // If we reach here without crashing, the test passes.
    #expect(samples.count == 4)
}
