import Foundation
import LocalCutCore

/// Testable latency estimate for the live monitor path.
///
/// Phase 46 cannot do a true hardware loopback measurement without external
/// routing. The estimator therefore records the parts LocalCut controls
/// directly and accepts hardware input/output latency as injectable values when
/// a caller can provide them.
nonisolated struct LiveMonitorLatencyMeasurement: Hashable, Sendable {
    static let defaultProcessingBufferFrames = 1024

    var inputLatencySeconds: Double
    var processingLatencySeconds: Double
    var queuedLatencySeconds: Double
    var outputLatencySeconds: Double
    var sampleRate: Double
    var processingBufferFrames: Int

    var totalSeconds: Double {
        [inputLatencySeconds, processingLatencySeconds, queuedLatencySeconds, outputLatencySeconds]
            .filter(\.isFinite)
            .reduce(0, +)
    }

    var totalMilliseconds: Double {
        totalSeconds * 1_000
    }

    static func measure(settings: VoiceCleanupSettings,
                        sampleRate: Double = 48_000,
                        inputLatencySeconds: Double = 0,
                        outputLatencySeconds: Double = 0,
                        queuedFrames: Int = 0,
                        processingBufferFrames: Int = Self.defaultProcessingBufferFrames) -> LiveMonitorLatencyMeasurement {
        let safeSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let processingFrames = max(0, processingBufferFrames)
        let queuedFrames = max(0, queuedFrames)
        let processingLatency = settings.requiresOfflineProcessing
            ? Double(processingFrames) / safeSampleRate
            : 0
        let queuedLatency = Double(queuedFrames) / safeSampleRate

        return LiveMonitorLatencyMeasurement(
            inputLatencySeconds: sanitizedLatency(inputLatencySeconds),
            processingLatencySeconds: processingLatency,
            queuedLatencySeconds: queuedLatency,
            outputLatencySeconds: sanitizedLatency(outputLatencySeconds),
            sampleRate: safeSampleRate,
            processingBufferFrames: processingFrames)
    }

    private static func sanitizedLatency(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
