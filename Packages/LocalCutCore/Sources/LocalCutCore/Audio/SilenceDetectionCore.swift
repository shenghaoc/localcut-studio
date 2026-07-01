import Foundation
import CoreMedia
import Accelerate

// MARK: - Silence Detection Core

/// Pure, deterministic silence-detection DSP. Operates on mono `Float` samples
/// at a known sample rate. Uses short-time RMS energy with hysteresis
/// thresholds to avoid chatter around the decision boundary.
public enum SilenceDetectionCore: Sendable {

    /// Detects silence regions in a mono audio signal.
    ///
    /// - Parameters:
    ///   - samples: Mono float samples (–1…1).
    ///   - sampleRate: The sample rate in Hz.
    ///   - parameters: Detection tuning parameters.
    /// - Returns: Detected silence regions (with padding) and proposed cuts.
    public static func analyze(
        samples: [Float],
        sampleRate: Double,
        parameters: SilenceDetectionParameters
    ) -> ([DetectedSilence], [ProposedCut]) {
        guard !samples.isEmpty, sampleRate > 0 else {
            return ([], [])
        }

        let blockSize = max(1, Int(sampleRate * 0.02)) // 20 ms blocks
        let openThreshold = parameters.openThresholdLinear
        let closeThreshold = parameters.closeThresholdLinear
        let minSilenceSamples = Int(parameters.minimumSilenceDuration.seconds * sampleRate)
        let paddingSamples = Int(parameters.padding.seconds * sampleRate)

        // Compute per-block RMS energy.
        let rmsValues = computeBlockRMS(samples: samples, blockSize: blockSize)
        let blockCount = rmsValues.count
        guard blockCount > 0 else {
            return ([], [])
        }

        // Hysteresis state machine: scan for silence regions.
        var silences: [DetectedSilence] = []
        var inSilence = false
        var silenceStartBlock = 0

        for i in 0..<blockCount {
            let rms = rmsValues[i]
            if !inSilence {
                // Silence opens when RMS drops below open threshold.
                if rms < openThreshold {
                    inSilence = true
                    silenceStartBlock = i
                }
            } else {
                // Silence closes when RMS rises above close threshold.
                if rms >= closeThreshold {
                    inSilence = false
                    let silenceEndBlock = i
                    let silenceBlockCount = silenceEndBlock - silenceStartBlock
                    if silenceBlockCount * blockSize >= minSilenceSamples {
                        appendSilence(
                            startBlock: silenceStartBlock, endBlock: silenceEndBlock,
                            blockSize: blockSize, sampleRate: sampleRate,
                            totalSamples: samples.count, paddingSamples: paddingSamples,
                            to: &silences)
                    }
                }
            }
        }

        // Handle trailing silence (still in silence at end of signal).
        if inSilence {
            let silenceEndBlock = blockCount
            let silenceBlockCount = silenceEndBlock - silenceStartBlock
            if silenceBlockCount * blockSize >= minSilenceSamples {
                appendSilence(
                    startBlock: silenceStartBlock, endBlock: silenceEndBlock,
                    blockSize: blockSize, sampleRate: sampleRate,
                    totalSamples: samples.count, paddingSamples: paddingSamples,
                    to: &silences)
            }
        }

        // Convert silences to proposed cuts.
        let proposedCuts = silences.map { silence in
            ProposedCut(
                silenceRange: silence.range,
                unpaddedSilenceRange: silence.unpaddedRange,
                suggestedAction: .trim,
                isSelected: true)
        }

        return (silences, proposedCuts)
    }

    // MARK: - Helpers

    private static func computeBlockRMS(samples: [Float], blockSize: Int) -> [Float] {
        let blockCount = samples.count / blockSize
        guard blockCount > 0 else { return [] }
        var rmsValues = [Float](repeating: 0, count: blockCount)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for i in 0..<blockCount {
                let offset = i * blockSize
                let count = min(blockSize, ptr.count - offset)
                var meanSquare: Float = 0
                vDSP_measqv(base + offset, 1, &meanSquare, vDSP_Length(count))
                rmsValues[i] = sqrt(meanSquare)
            }
        }
        return rmsValues
    }

    private static func appendSilence(
        startBlock: Int, endBlock: Int,
        blockSize: Int, sampleRate: Double,
        totalSamples: Int, paddingSamples: Int,
        to silences: inout [DetectedSilence]
    ) {
        let startSample = startBlock * blockSize
        let endSample = endBlock * blockSize
        let unpaddedStart = CMTime(seconds: Double(startSample) / sampleRate,
                                   preferredTimescale: 600)
        let unpaddedDuration = CMTime(seconds: Double(endSample - startSample) / sampleRate,
                                      preferredTimescale: 600)
        let unpaddedRange = CMTimeRange(start: unpaddedStart, duration: unpaddedDuration)

        // Apply padding, clamped to valid range.
        let paddedStart = CMTime(seconds: max(0, Double(startSample - paddingSamples)) / sampleRate,
                                 preferredTimescale: 600)
        let paddedEnd = CMTime(seconds: min(Double(totalSamples),
                                            Double(endSample + paddingSamples)) / sampleRate,
                               preferredTimescale: 600)
        let paddedDuration = CMTime(seconds: max(0, paddedEnd.seconds - paddedStart.seconds),
                                    preferredTimescale: 600)
        let paddedRange = CMTimeRange(start: paddedStart, duration: paddedDuration)

        silences.append(DetectedSilence(range: paddedRange, unpaddedRange: unpaddedRange))
    }
}
