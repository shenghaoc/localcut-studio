import Foundation
import AVFoundation

// MARK: - Time Pitch Algorithm

/// Audio stretch quality used when a retimed clip preserves pitch.
public nonisolated enum TimePitchAlgorithm: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case timeDomain
    case spectral

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .timeDomain: "Time Domain"
        case .spectral: "Spectral"
        }
    }

    public var avFoundationAlgorithm: AVAudioTimePitchAlgorithm {
        switch self {
        case .timeDomain: .timeDomain
        case .spectral: .spectral
        }
    }
}

// MARK: - Time Remap Segment

/// One piecewise-constant segment in a clip's source-to-output retime plan.
public nonisolated struct TimeRemapSegment: Hashable, Sendable {
    /// Absolute source-media range to insert.
    public var sourceRange: CMTimeRange
    /// Clip-local output offset where this source range begins.
    public var outputOffset: CMTime
    /// Timeline duration after retiming this source range.
    public var outputDuration: CMTime
    /// Constant speed approximation for this segment.
    public var speed: Float

    public var outputRange: CMTimeRange {
        CMTimeRange(start: outputOffset, duration: outputDuration)
    }

    public init(sourceRange: CMTimeRange, outputOffset: CMTime,
                outputDuration: CMTime, speed: Float) {
        self.sourceRange = sourceRange
        self.outputOffset = outputOffset
        self.outputDuration = outputDuration
        self.speed = speed
    }
}

// MARK: - Time Remapping

/// Pure speed-ramp math shared by the model, timeline layout, and composition builder.
public nonisolated enum TimeRemapping {
    public static let minSpeed: Float = 0.25
    public static let maxSpeed: Float = 4.0
    public static let identitySpeed: Float = 1.0
    public static let defaultSegmentsPerKeyframePair = 10
    public static let timeToleranceSeconds = 1.0 / 600.0

    public static var identitySpeedCurve: Keyframed<Float> {
        Keyframed<Float>(defaultValue: identitySpeed)
    }

    public static func clampedSpeed(_ value: Float) -> Float {
        guard value.isFinite else { return identitySpeed }
        return min(max(value, minSpeed), maxSpeed)
    }

    public static func clampedCurve(_ curve: Keyframed<Float>) -> Keyframed<Float> {
        let keyframes = curve.keyframes.map { keyframe in
            Keyframe<Float>(
                id: keyframe.id,
                time: CMTimeMaximum(.zero, keyframe.time.sanitized),
                value: clampedSpeed(keyframe.value))
        }
        return Keyframed<Float>(
            keyframes: keyframes,
            defaultValue: clampedSpeed(curve.defaultValue))
    }

    public static func hasNonIdentitySpeed(_ curve: Keyframed<Float>) -> Bool {
        let curve = clampedCurve(curve)
        if abs(curve.defaultValue - identitySpeed) > 0.0001 { return true }
        return curve.keyframes.contains { abs($0.value - identitySpeed) > 0.0001 }
    }

    /// Builds a local source-domain plan from source offset 0 through `sourceDuration`.
    ///
    /// Speed keyframe times are clip-source-relative. This keeps source trims stable
    /// and lets other features map source timestamps (captions, beats) onto the
    /// retimed timeline without circular output-duration dependencies.
    public static func segmentPlan(sourceDuration: CMTime,
                                   speedCurve rawCurve: Keyframed<Float>,
                                   segmentsPerKeyframePair rawSegments: Int = defaultSegmentsPerKeyframePair)
        -> [TimeRemapSegment] {
        let sourceDuration = sourceDuration.sanitized
        guard sourceDuration > .zero else { return [] }

        let curve = clampedCurve(rawCurve)
        let sourceEnd = sourceDuration
        let segmentsPerPair = max(1, rawSegments)
        var boundaries = Set<CMTime>([.zero, sourceEnd])
        for keyframe in curve.keyframes {
            let time = CMTimeMinimum(CMTimeMaximum(.zero, keyframe.time.sanitized), sourceEnd)
            boundaries.insert(time)
        }
        let sortedBounds = boundaries.sorted()

        var plan: [TimeRemapSegment] = []
        var outputOffset = CMTime.zero
        for index in 0..<(sortedBounds.count - 1) {
            let lower = sortedBounds[index]
            let upper = sortedBounds[index + 1]
            let interval = upper - lower
            guard interval > .zero else { continue }

            let subdivisions = curve.keyframes.count > 1 ? segmentsPerPair : 1
            for subIndex in 0..<subdivisions {
                let startFraction = Double(subIndex) / Double(subdivisions)
                let endFraction = Double(subIndex + 1) / Double(subdivisions)
                let localStart = lower + multiplied(interval, by: startFraction)
                let localEnd = lower + multiplied(interval, by: endFraction)
                let sourceRange = CMTimeRange(start: localStart, end: localEnd)
                guard sourceRange.duration > .zero else { continue }

                let midpoint = sourceRange.start + multiplied(sourceRange.duration, by: 0.5)
                let speed = clampedSpeed(curve.value(at: midpoint))
                let outputDuration = multiplied(sourceRange.duration, by: 1.0 / Double(speed))
                plan.append(TimeRemapSegment(
                    sourceRange: sourceRange,
                    outputOffset: outputOffset,
                    outputDuration: outputDuration,
                    speed: speed))
                outputOffset = outputOffset + outputDuration
            }
        }
        return plan
    }

    /// Builds an absolute-source plan for a whole clip or a requested subrange.
    public static func segmentPlan(for clip: Clip,
                                   sourceRange requestedSourceRange: CMTimeRange? = nil,
                                   segmentsPerKeyframePair: Int = defaultSegmentsPerKeyframePair)
        -> [TimeRemapSegment] {
        let localPlan = segmentPlan(
            sourceDuration: clip.duration,
            speedCurve: clip.speedCurve,
            segmentsPerKeyframePair: segmentsPerKeyframePair)
        guard !localPlan.isEmpty else { return [] }

        let requested = requestedSourceRange ?? clip.timeRangeInSource
        var result: [TimeRemapSegment] = []
        for local in localPlan {
            let absolute = CMTimeRange(
                start: clip.sourceStart + local.sourceRange.start,
                duration: local.sourceRange.duration)
            let clipped = absolute.intersection(requested)
            guard clipped.duration > .zero else { continue }

            let sourceStartDelta = clipped.start - absolute.start
            let sourceEndDelta = clipped.end - absolute.start
            let startFraction = fraction(sourceStartDelta, of: absolute.duration)
            let endFraction = fraction(sourceEndDelta, of: absolute.duration)
            let outputStart = local.outputOffset + multiplied(local.outputDuration, by: startFraction)
            let outputEnd = local.outputOffset + multiplied(local.outputDuration, by: endFraction)
            let outputDuration = outputEnd - outputStart
            guard outputDuration > .zero else { continue }

            result.append(TimeRemapSegment(
                sourceRange: clipped,
                outputOffset: outputStart,
                outputDuration: outputDuration,
                speed: local.speed))
        }
        return result
    }

    public static func outputDuration(sourceDuration: CMTime,
                                      speedCurve: Keyframed<Float>) -> CMTime {
        segmentPlan(sourceDuration: sourceDuration, speedCurve: speedCurve)
            .reduce(CMTime.zero) { $0 + $1.outputDuration }
    }

    public static func sourceOffset(forOutputOffset outputOffset: CMTime,
                                    sourceDuration: CMTime,
                                    speedCurve: Keyframed<Float>) -> CMTime {
        let plan = segmentPlan(sourceDuration: sourceDuration, speedCurve: speedCurve)
        guard !plan.isEmpty else { return .zero }
        let totalOutput = plan.reduce(CMTime.zero) { $0 + $1.outputDuration }
        let target = CMTimeMinimum(CMTimeMaximum(.zero, outputOffset.sanitized), totalOutput)

        for segment in plan {
            let end = segment.outputOffset + segment.outputDuration
            if target <= end || abs((target - end).seconds) <= timeToleranceSeconds {
                let relative = target - segment.outputOffset
                let progress = fraction(relative, of: segment.outputDuration)
                return segment.sourceRange.start + multiplied(segment.sourceRange.duration, by: progress)
            }
        }
        return sourceDuration.sanitized
    }

    public static func outputOffset(forSourceOffset sourceOffset: CMTime,
                                    sourceDuration: CMTime,
                                    speedCurve: Keyframed<Float>) -> CMTime {
        let plan = segmentPlan(sourceDuration: sourceDuration, speedCurve: speedCurve)
        guard !plan.isEmpty else { return .zero }
        let target = CMTimeMinimum(CMTimeMaximum(.zero, sourceOffset.sanitized), sourceDuration.sanitized)

        for segment in plan {
            if target <= segment.sourceRange.end
                || abs((target - segment.sourceRange.end).seconds) <= timeToleranceSeconds {
                let relative = target - segment.sourceRange.start
                let progress = fraction(relative, of: segment.sourceRange.duration)
                return segment.outputOffset + multiplied(segment.outputDuration, by: progress)
            }
        }
        return plan.reduce(CMTime.zero) { $0 + $1.outputDuration }
    }

    static func multiplied(_ time: CMTime, by multiplier: Double) -> CMTime {
        guard time.isNumeric, time.seconds.isFinite, multiplier.isFinite else { return .zero }
        return CMTime(seconds: max(0, time.seconds * multiplier), preferredTimescale: 600)
    }

    private static func fraction(_ time: CMTime, of duration: CMTime) -> Double {
        guard duration > .zero, duration.seconds.isFinite else { return 0 }
        return min(1, max(0, time.seconds / duration.seconds))
    }
}
