import Foundation
import CoreMedia

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

}

// MARK: - Time Remap Segment

/// One piecewise-constant segment in a clip's source-to-output retime plan.
public nonisolated struct TimeRemapSegment: Hashable, Sendable {
    /// Absolute source-media range to insert.
    public let sourceRange: CMTimeRange
    /// Clip-local output offset where this source range begins.
    public let outputOffset: CMTime
    /// Timeline duration after retiming this source range.
    public let outputDuration: CMTime
    /// Constant speed approximation for this segment.
    public let speed: Float

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
public nonisolated enum TimeRemapping: Sendable {
    public static let minSpeed: Float = 0.25
    public static let maxSpeed: Float = 4.0
    public static let identitySpeed: Float = 1.0
    public static let defaultSegmentsPerKeyframePair = 10

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
                value: clampedSpeed(keyframe.value),
                incomingHandle: clampedHandle(keyframe.incomingHandle),
                outgoingHandle: clampedHandle(keyframe.outgoingHandle))
        }
        return Keyframed<Float>(
            keyframes: keyframes,
            defaultValue: clampedSpeed(curve.defaultValue))
    }

    public static func hasNonIdentitySpeed(_ curve: Keyframed<Float>) -> Bool {
        if abs(clampedSpeed(curve.defaultValue) - identitySpeed) > 0.0001 { return true }
        return curve.keyframes.contains { keyframe in
            abs(clampedSpeed(keyframe.value) - identitySpeed) > 0.0001
                || handleIsNonIdentity(keyframe.incomingHandle)
                || handleIsNonIdentity(keyframe.outgoingHandle)
        }
    }

    public static func speedValue(in curve: Keyframed<Float>, at time: CMTime) -> Float {
        clampedSpeed(clampedCurve(curve).bezierValue(at: time.sanitized))
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

            // Only subdivide when the interval actually contains a speed ramp.
            // An interval whose endpoint speeds match is constant and needs
            // just one segment. Evaluating at the endpoints (rather than
            // filtering keyframes by time) avoids CMTime comparison edge cases.
            let speedAtLower = clampedSpeed(curve.bezierValue(at: lower))
            let speedAtUpper = clampedSpeed(curve.bezierValue(at: upper))
            let speedsVary = segmentNeedsSubdivisions(
                curve: curve,
                lower: lower,
                upper: upper,
                speedAtLower: speedAtLower,
                speedAtUpper: speedAtUpper)
            let subdivisions = speedsVary ? segmentsPerPair : 1
            for subIndex in 0..<subdivisions {
                let startFraction = Double(subIndex) / Double(subdivisions)
                let endFraction = Double(subIndex + 1) / Double(subdivisions)
                let localStart = lower + multiplied(interval, by: startFraction)
                let localEnd = lower + multiplied(interval, by: endFraction)
                let sourceRange = CMTimeRange(start: localStart, end: localEnd)
                guard sourceRange.duration > .zero else { continue }

                let midpoint = sourceRange.start + multiplied(sourceRange.duration, by: 0.5)
                let speed = clampedSpeed(curve.bezierValue(at: midpoint))
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

    /// Snaps internal segment boundaries to the nearest source sample time while
    /// preserving the original output ranges. The source span remains exact at
    /// the outer boundaries; only internal cuts move, bounded by the caller's
    /// source sample duration.
    public static func snapSegmentPlan(_ plan: [TimeRemapSegment],
                                       toSourceSampleDuration sampleDuration: CMTime)
        -> [TimeRemapSegment] {
        guard plan.count > 1,
              sampleDuration.isNumeric,
              sampleDuration > .zero,
              sampleDuration.seconds.isFinite else { return plan }

        var boundaries: [CMTime] = [plan[0].sourceRange.start]
        for index in 0..<(plan.count - 1) {
            let original = plan[index].sourceRange.end
            let previous = boundaries.last ?? plan[index].sourceRange.start
            let nextOriginal = plan[index + 1].sourceRange.end
            let snapped = nearestSampleTime(original, sampleDuration: sampleDuration)
            if snapped > previous, snapped < nextOriginal {
                boundaries.append(snapped)
            } else {
                boundaries.append(original)
            }
        }
        boundaries.append(plan[plan.count - 1].sourceRange.end)

        var snappedPlan: [TimeRemapSegment] = []
        snappedPlan.reserveCapacity(plan.count)
        for index in plan.indices {
            let sourceRange = CMTimeRange(start: boundaries[index], end: boundaries[index + 1])
            guard sourceRange.duration > .zero else { continue }
            let outputDuration = plan[index].outputDuration
            let speed: Float
            if outputDuration > .zero {
                speed = clampedSpeed(Float(sourceRange.duration.seconds / outputDuration.seconds))
            } else {
                speed = plan[index].speed
            }
            snappedPlan.append(TimeRemapSegment(
                sourceRange: sourceRange,
                outputOffset: plan[index].outputOffset,
                outputDuration: outputDuration,
                speed: speed))
        }
        return snappedPlan
    }

    public static func outputDuration(sourceDuration: CMTime,
                                      speedCurve: Keyframed<Float>) -> CMTime {
        segmentPlan(sourceDuration: sourceDuration, speedCurve: speedCurve)
            .reduce(CMTime.zero) { $0 + $1.outputDuration }
    }

    public static func outputDuration(for plan: [TimeRemapSegment]) -> CMTime {
        plan.reduce(CMTime.zero) { $0 + $1.outputDuration }
    }

    public static func sourceOffset(forOutputOffset outputOffset: CMTime,
                                    sourceDuration: CMTime,
                                    speedCurve: Keyframed<Float>) -> CMTime {
        let plan = segmentPlan(sourceDuration: sourceDuration, speedCurve: speedCurve)
        guard !plan.isEmpty else { return .zero }
        let totalOutput = plan.reduce(CMTime.zero) { $0 + $1.outputDuration }
        let target = CMTimeMinimum(CMTimeMaximum(.zero, outputOffset.sanitized), totalOutput)

        // `target` is clamped to `totalOutput`, which equals the last segment's
        // accumulated end exactly, so `target <= end` always matches there. No
        // tolerance band — it would snap a target just past an intermediate
        // boundary back onto the previous segment.
        for segment in plan {
            let end = segment.outputOffset + segment.outputDuration
            if target <= end {
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
        return outputOffset(forSourceOffset: sourceOffset, in: plan)
    }

    public static func outputOffset(forSourceOffset sourceOffset: CMTime,
                                    in plan: [TimeRemapSegment]) -> CMTime {
        guard let first = plan.first, let last = plan.last else { return .zero }
        let target = CMTimeMinimum(
            CMTimeMaximum(first.sourceRange.start, sourceOffset.sanitized),
            last.sourceRange.end)

        // `target` is clamped to the plan's source bounds, so the last segment's
        // source end always matches exactly.
        // No tolerance band — it would snap a target just past an intermediate
        // boundary back onto the previous segment.
        for segment in plan {
            if target <= segment.sourceRange.end {
                let relative = target - segment.sourceRange.start
                let progress = fraction(relative, of: segment.sourceRange.duration)
                return segment.outputOffset + multiplied(segment.outputDuration, by: progress)
            }
        }
        return outputDuration(for: plan)
    }

    public static func affectedSourceRange(before oldCurve: Keyframed<Float>,
                                           after newCurve: Keyframed<Float>,
                                           sourceDuration: CMTime) -> CMTimeRange? {
        let duration = sourceDuration.sanitized
        guard duration > .zero else { return nil }
        let old = clampedCurve(oldCurve)
        let new = clampedCurve(newCurve)
        guard old != new else { return nil }

        if old.keyframes.isEmpty || new.keyframes.isEmpty {
            return CMTimeRange(start: .zero, duration: duration)
        }

        let count = max(old.keyframes.count, new.keyframes.count)
        var changedTimes: [CMTime] = []
        for index in 0..<count {
            if index >= old.keyframes.count {
                changedTimes.append(new.keyframes[index].time)
            } else if index >= new.keyframes.count {
                changedTimes.append(old.keyframes[index].time)
            } else if old.keyframes[index] != new.keyframes[index] {
                changedTimes.append(old.keyframes[index].time)
                changedTimes.append(new.keyframes[index].time)
            }
        }

        guard let minChanged = changedTimes.min(),
              let maxChanged = changedTimes.max() else { return nil }
        let boundaries = ([CMTime.zero, duration]
            + old.keyframes.map(\.time)
            + new.keyframes.map(\.time))
            .map { CMTimeMinimum(CMTimeMaximum(.zero, $0.sanitized), duration) }
            .sorted()
        let lower = boundaries.last(where: { $0 < minChanged }) ?? .zero
        let upper = boundaries.first(where: { $0 > maxChanged }) ?? duration
        guard upper > lower else {
            return CMTimeRange(start: .zero, duration: duration)
        }
        return CMTimeRange(start: lower, end: upper)
    }

    public static func multiplied(_ time: CMTime, by multiplier: Double) -> CMTime {
        guard time.isNumeric, time.seconds.isFinite, multiplier.isFinite else { return .zero }
        // Preserve the input's timescale so retimed high-rate audio times
        // (44.1k/48k) don't quantise to a coarse 600 grid, while keeping 600 as a
        // floor so coarse inputs never regress below the previous precision.
        let timescale = max(time.timescale, CMTimeScale(600))
        return CMTime(seconds: max(0, time.seconds * multiplier), preferredTimescale: timescale)
    }

    private static func fraction(_ time: CMTime, of duration: CMTime) -> Double {
        guard duration > .zero, duration.seconds.isFinite else { return 0 }
        return min(1, max(0, time.seconds / duration.seconds))
    }

    private static func clampedHandle(_ handle: KeyframeHandle?) -> KeyframeHandle? {
        guard let handle,
              handle.x.isFinite,
              handle.y.isFinite else { return nil }
        return KeyframeHandle(
            x: min(1, max(0, handle.x)),
            y: clampedSpeed(handle.y))
    }

    private static func handleIsNonIdentity(_ handle: KeyframeHandle?) -> Bool {
        guard let handle else { return false }
        return abs(clampedSpeed(handle.y) - identitySpeed) > 0.0001
    }

    private static func segmentNeedsSubdivisions(curve: Keyframed<Float>,
                                                 lower: CMTime,
                                                 upper: CMTime,
                                                 speedAtLower: Float,
                                                 speedAtUpper: Float) -> Bool {
        if abs(speedAtLower - speedAtUpper) > 0.0001 { return true }
        guard let lowerKeyframe = curve.keyframes.first(where: { $0.time == lower }),
              let upperKeyframe = curve.keyframes.first(where: { $0.time == upper }) else {
            return false
        }
        let lowerSpeed = clampedSpeed(lowerKeyframe.value)
        let upperSpeed = clampedSpeed(upperKeyframe.value)
        if let outgoing = lowerKeyframe.outgoingHandle {
            let expected = lowerSpeed + (upperSpeed - lowerSpeed) * clampedUnit(outgoing.x)
            if abs(clampedSpeed(outgoing.y) - expected) > 0.0001 { return true }
        }
        if let incoming = upperKeyframe.incomingHandle {
            let expected = upperSpeed - (upperSpeed - lowerSpeed) * clampedUnit(incoming.x)
            if abs(clampedSpeed(incoming.y) - expected) > 0.0001 { return true }
        }
        return false
    }

    private static func clampedUnit(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 / 3.0 }
        return min(1, max(0, value))
    }

    private static func nearestSampleTime(_ time: CMTime,
                                          sampleDuration: CMTime) -> CMTime {
        guard time.isNumeric,
              sampleDuration.isNumeric,
              sampleDuration > .zero else { return time }
        let sampleSeconds = sampleDuration.seconds
        guard sampleSeconds.isFinite, sampleSeconds > 0 else { return time }
        let snappedSeconds = (time.seconds / sampleSeconds).rounded() * sampleSeconds
        let timescale = max(max(time.timescale, sampleDuration.timescale), CMTimeScale(600))
        return CMTime(seconds: max(0, snappedSeconds), preferredTimescale: timescale)
    }
}
