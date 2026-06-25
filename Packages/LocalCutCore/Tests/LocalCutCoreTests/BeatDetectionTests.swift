import Testing
import Foundation
import CoreMedia
import LocalCutCore

@Suite("Beat tools — detection core")
struct BeatDetectionCoreTests {

    @Test("Adaptive peak picker finds local onsets above the running median")
    func peakPicker() {
        let envelope: [Float] = [0, 0.02, 0.1, 0.9, 0.12, 0.03, 0.02, 0.2, 0.95, 0.18, 0.04]

        let peaks = BeatDetectionCore.pickOnsetPeaks(envelope, medianRadius: 2, delta: 0.2, minDistance: 2)

        #expect(peaks == [3, 8])
    }

    @Test("Autocorrelation tempo estimate recovers a regular 120 BPM envelope")
    func tempoEstimate() {
        var envelope = Array(repeating: Float(0), count: 80)
        for index in stride(from: 0, to: envelope.count, by: 10) {
            envelope[index] = 1
        }

        let bpm = BeatDetectionCore.estimateTempoBPM(envelope: envelope, hopDuration: 0.05)

        #expect(abs(bpm - 120) < 0.1)
    }

    @Test("Beat times quantise onto the project CMTime timescale")
    func quantisation() {
        let time = BeatDetectionCore.quantizedTime(seconds: 1.0 / 3.0)

        #expect(time.timescale == 600)
        #expect(time.value == 200)
    }

    @Test("Analysing the same synthetic fixture twice is deterministic")
    func deterministicSyntheticAnalysis() throws {
        let samples = pulseTrain(sampleRate: 22_050, duration: 6, interval: 0.5)

        let first = try BeatDetectionCore.analyze(samples: samples, sampleRate: 22_050)
        let second = try BeatDetectionCore.analyze(samples: samples, sampleRate: 22_050)

        #expect(first == second)
        #expect(!first.beatTimes.isEmpty)
    }

    @Test("DP beat track-back places beats near onset peaks")
    func dpBeatTrackSnapsToPeaks() {
        // Create an envelope with peaks at frames 10, 20, 30, 40 (every 10 frames).
        // With hopDuration 0.05, these are at 0.5, 1.0, 1.5, 2.0 seconds.
        // Tempo 120 BPM → interval 0.5s → grid aligns perfectly.
        var envelope = Array(repeating: Float(0), count: 60)
        for i in stride(from: 10, to: 60, by: 10) { envelope[i] = 1.0 }
        let peaks = [10, 20, 30, 40]

        let beats = BeatDetectionCore.dpBeatTrack(
            peaks: peaks, tempoBPM: 120, hopDuration: 0.05,
            envelope: envelope, durationSeconds: 2.5)

        // Beats should snap to the peak positions
        #expect(beats.count >= 4)
        let beatSeconds = beats.map(\.seconds)
        #expect(abs(beatSeconds[0] - 0.5) < 0.1)
        #expect(abs(beatSeconds[1] - 1.0) < 0.1)
        #expect(abs(beatSeconds[2] - 1.5) < 0.1)
        #expect(abs(beatSeconds[3] - 2.0) < 0.1)
    }

    @Test("Versioned cache header round-trips beat analysis")
    func cacheRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("beat-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = BeatAnalysis(
            tempoBPM: 120,
            beatTimes: [
                CMTime(seconds: 0.5, preferredTimescale: 600),
                CMTime(seconds: 1.0, preferredTimescale: 600)
            ],
            confidence: 0.75)

        try BeatAnalysisCache.write(analysis, key: "abc123", in: directory)
        let restoredOptional = try BeatAnalysisCache.read(key: "abc123", in: directory)
        let restored = try #require(restoredOptional)

        #expect(restored == analysis)
    }

    private func pulseTrain(sampleRate: Int, duration: Double, interval: Double) -> [Float] {
        let count = Int(Double(sampleRate) * duration)
        var samples = Array(repeating: Float(0), count: count)
        var time = 0.0
        while time < duration {
            let start = Int(time * Double(sampleRate))
            for offset in 0..<min(128, count - start) {
                samples[start + offset] = 1
            }
            time += interval
        }
        return samples
    }
}
