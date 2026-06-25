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
