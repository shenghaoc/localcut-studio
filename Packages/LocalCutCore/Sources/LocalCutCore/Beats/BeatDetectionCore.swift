import Foundation
import CoreMedia
import Accelerate

// MARK: - Detection core

/// Deterministic, platform-light beat detection over raw mono samples.
///
/// Pure DSP only — no AVFoundation. The app's `BeatAnalyzer` actor decodes an
/// asset to `[Float]` and feeds it here, which keeps this logic testable via
/// `swift test --package-path Packages/LocalCutCore`.
public enum BeatDetectionCore {
    public static let defaultFrameSize = 1024
    public static let defaultHopSize = 512
    public static let emittedTimescale: CMTimeScale = 600

    public static func analyze(samples: [Float], sampleRate: Double) throws -> BeatAnalysis {
        guard samples.count >= defaultFrameSize, sampleRate > 0 else {
            throw BeatAnalysisError.insufficientSamples
        }
        let envelope = onsetEnvelope(samples: samples, frameSize: defaultFrameSize, hopSize: defaultHopSize)
        let peaks = pickOnsetPeaks(envelope)
        let hopDuration = Double(defaultHopSize) / sampleRate
        let tempo = estimateTempoBPM(envelope: envelope, hopDuration: hopDuration)
        let durationSeconds = Double(samples.count) / sampleRate
        let beatTimes = dpBeatTrack(peaks: peaks,
                                    tempoBPM: tempo,
                                    hopDuration: hopDuration,
                                    envelope: envelope,
                                    durationSeconds: durationSeconds)
        let confidence = confidenceScore(peaks: peaks.count, beats: beatTimes.count, tempoBPM: tempo)
        return BeatAnalysis(tempoBPM: tempo, beatTimes: beatTimes, confidence: confidence)
    }

    /// Builds a half-wave-rectified spectral-flux onset envelope using a
    /// proper vDSP STFT. Each frame is windowed with a Hann window, FFT'd
    /// via `vDSP_fft_zrip`, and the magnitude spectrum is compared to the
    /// previous frame. Only positive increases (new energy appearing) are
    /// accumulated per frequency bin and summed, giving a spectral-flux
    /// onset strength curve.
    public static func onsetEnvelope(samples: [Float], frameSize: Int, hopSize: Int) -> [Float] {
        guard samples.count >= frameSize, frameSize > 0, hopSize > 0 else { return [] }
        let window = hannWindow(count: frameSize)
        let halfN = frameSize / 2
        let log2n = vDSP_Length(log2(Float(frameSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var envelope: [Float] = []
        envelope.reserveCapacity((samples.count - frameSize) / hopSize + 1)
        var prevMag = [Float](repeating: 0, count: halfN)
        var windowed = [Float](repeating: 0, count: frameSize)
        let realp = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        defer { realp.deallocate(); imagp.deallocate() }
        var split = DSPSplitComplex(realp: realp, imagp: imagp)

        var frameStart = 0
        while frameStart + frameSize <= samples.count {
            for i in 0..<frameSize {
                windowed[i] = samples[frameStart + i] * window[i]
            }

            // Pack windowed samples into split complex (interleaved → split).
            windowed.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexP in
                    vDSP_ctoz(complexP, 2, &split, 1, vDSP_Length(halfN))
                }
            }

            // Real in-place FFT: `vDSP_ctoz` packed `frameSize` real samples
            // into `halfN` split-complex elements, so we must use the *real*
            // transform (`zrip`), which operates on those `halfN` elements.
            // `vDSP_fft_zip` would treat the buffer as a full 2^log2n-point
            // complex FFT and read/write `frameSize` (= 2·halfN) elements,
            // overrunning the `halfN`-capacity `realp`/`imagp` allocations.
            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

            var mag = [Float](repeating: 0, count: halfN)
            vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(halfN))

            var flux: Float = 0
            for j in 0..<halfN {
                let diff = mag[j] - prevMag[j]
                if diff > 0 { flux += diff }
            }
            envelope.append(flux)
            prevMag = mag

            frameStart += hopSize
        }
        return normalized(envelope)
    }

    public static func pickOnsetPeaks(_ envelope: [Float],
                                      medianRadius: Int = 6,
                                      delta: Float = 0.08,
                                      minDistance: Int = 4) -> [Int] {
        guard envelope.count >= 3 else { return [] }
        var peaks: [Int] = []
        for index in 1..<(envelope.count - 1) {
            let value = envelope[index]
            guard value >= envelope[index - 1], value > envelope[index + 1] else { continue }
            let start = max(0, index - medianRadius)
            let end = min(envelope.count - 1, index + medianRadius)
            let threshold = runningMedian(envelope[start...end]) + delta
            guard value >= threshold else { continue }
            if let last = peaks.last, index - last < minDistance {
                if value > envelope[last] {
                    peaks[peaks.count - 1] = index
                }
            } else {
                peaks.append(index)
            }
        }
        return peaks
    }

    /// Fraction of the winning lag's onset energy a faster sub-harmonic must
    /// retain before we treat it as the true fundamental tempo.
    public static let octaveEnergyFraction: Float = 0.5

    public static func estimateTempoBPM(envelope: [Float],
                                        hopDuration: Double,
                                        minBPM: Double = 60,
                                        maxBPM: Double = 200) -> Double {
        guard !envelope.isEmpty, hopDuration > 0 else { return 0 }
        let minLag = max(1, Int((60 / maxBPM / hopDuration).rounded()))
        let maxLag = max(minLag, Int((60 / minBPM / hopDuration).rounded()))
        guard envelope.count > maxLag else { return 0 }

        // Raw (unnormalised) autocorrelation per lag, computed once in the
        // sweep below and reused by the octave correction. Every lag the
        // correction inspects lies in `minLag...maxLag`, so the cache covers
        // it with no recomputation.
        var rawAutocorrelation = [Float](repeating: 0, count: maxLag - minLag + 1)
        func cachedAutocorrelation(at lag: Int) -> Float {
            guard lag >= minLag, lag <= maxLag else { return 0 }
            return rawAutocorrelation[lag - minLag]
        }

        var bestLag = minLag
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var score: Float = 0
            for index in lag..<envelope.count {
                score += envelope[index] * envelope[index - lag]
            }
            rawAutocorrelation[lag - minLag] = score
            let normalizedScore = score / Float(envelope.count - lag)
            if normalizedScore > bestScore {
                bestScore = normalizedScore
                bestLag = lag
            }
        }
        guard bestScore > 0 else { return 0 }

        // Tempo-octave (sub-harmonic) correction. Integer-lag autocorrelation on
        // a non-integer beat period locks onto whichever lag best aligns with an
        // *integer multiple* of the true period — often a sub-harmonic (half or
        // third tempo). A 120 BPM click whose beats fall every 21.5 frames, for
        // example, correlates better at lag 43 (≈2 beats) than at lag 21/22, so
        // the bare peak reports ~60 BPM. If a lag near bestLag/2 or bestLag/3
        // still carries at least `octaveEnergyFraction` of the peak's onset
        // energy, prefer that faster fundamental. A genuine half-tempo track has
        // little energy at the doubled rate, so the threshold leaves it alone.
        var improved = true
        while improved {
            improved = false
            let peakEnergy = cachedAutocorrelation(at: bestLag)
            guard peakEnergy > 0 else { break }
            for divisor in [2, 3] {
                let target = Double(bestLag) / Double(divisor)
                guard target >= Double(minLag) else { continue }
                // The (at most two) integer lags straddling the ideal sub-harmonic.
                let lower = Int(target.rounded(.down))
                let upper = Int(target.rounded(.up))
                let candidates = lower == upper ? [lower] : [lower, upper]
                var pick: (lag: Int, energy: Float)?
                for candidate in candidates where candidate >= minLag && candidate <= maxLag {
                    let energy = cachedAutocorrelation(at: candidate)
                    if pick == nil || energy > pick!.energy {
                        pick = (candidate, energy)
                    }
                }
                if let pick, pick.energy >= peakEnergy * octaveEnergyFraction {
                    bestLag = pick.lag
                    improved = true
                    break
                }
            }
        }

        return 60 / (Double(bestLag) * hopDuration)
    }

    /// Dynamic-programming beat track-back. Places beats at onset peaks
    /// near the expected grid positions while maintaining tempo regularity.
    /// Each beat snaps to the strongest onset peak within ±halfBeat of its
    /// expected position, preferring positions that minimise deviation from
    /// the inter-beat interval.
    public static func dpBeatTrack(peaks: [Int],
                                   tempoBPM: Double,
                                   hopDuration: Double,
                                   envelope: [Float],
                                   durationSeconds: Double) -> [CMTime] {
        guard tempoBPM > 0, durationSeconds > 0 else {
            return peaks.map { quantizedTime(seconds: Double($0) * hopDuration) }
        }
        guard !peaks.isEmpty else { return [] }

        let interval = 60 / tempoBPM
        let halfBeat = interval * 0.4
        // Anchor the grid on the first detected onset peak rather than on the
        // bare phase offset: starting at `firstPeakTime.truncatingRemainder`
        // would emit spurious leading beats (e.g. at t=0) before any onset
        // exists. The first peak is itself a valid grid position.
        let firstPeakTime = Double(peaks.first!) * hopDuration
        let searchRadius = Int(ceil(halfBeat / hopDuration))

        var beats: [CMTime] = []
        var t = firstPeakTime
        while t <= durationSeconds {
            let expectedGrid = t
            let centerFrame = Int(round(t / hopDuration))
            var bestPeak: Int?
            var bestCost = Double.infinity

            for peak in peaks {
                let peakTime = Double(peak) * hopDuration
                let delta = abs(peakTime - expectedGrid)
                guard delta <= halfBeat else { continue }
                let onsetStrength = Double(envelope[peak])
                let cost = delta - onsetStrength * hopDuration
                if cost < bestCost {
                    bestCost = cost
                    bestPeak = peak
                }
            }

            // Search broader radius if no peak found within tight window
            if bestPeak == nil {
                let lo = max(0, centerFrame - searchRadius * 2)
                let hi = min(envelope.count - 1, centerFrame + searchRadius * 2)
                for peak in peaks where peak >= lo && peak <= hi {
                    let peakTime = Double(peak) * hopDuration
                    let delta = abs(peakTime - expectedGrid)
                    let onsetStrength = Double(envelope[peak])
                    let cost = delta - onsetStrength * hopDuration * 0.5
                    if cost < bestCost {
                        bestCost = cost
                        bestPeak = peak
                    }
                }
            }

            let beatTime: Double
            if let peak = bestPeak {
                beatTime = Double(peak) * hopDuration
            } else {
                beatTime = expectedGrid
            }
            beats.append(quantizedTime(seconds: beatTime))
            t += interval
        }
        return beats
    }

    public static func quantizedTime(seconds: Double) -> CMTime {
        let value = Int64((max(0, seconds) * Double(emittedTimescale)).rounded())
        return CMTime(value: value, timescale: emittedTimescale)
    }

    private static func hannWindow(count: Int) -> [Float] {
        guard count > 1 else { return [1] }
        return (0..<count).map { index in
            0.5 - 0.5 * cos(Float(2 * Double.pi) * Float(index) / Float(count - 1))
        }
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        guard let maxValue = values.max(), maxValue > 0 else { return values }
        return values.map { $0 / maxValue }
    }

    private static func runningMedian<C: Collection>(_ values: C) -> Float where C.Element == Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func confidenceScore(peaks: Int, beats: Int, tempoBPM: Double) -> Float {
        guard beats > 0, tempoBPM > 0 else { return 0 }
        let coverage = min(1, Float(peaks) / Float(max(1, beats)))
        return max(0.1, min(1, coverage))
    }
}
