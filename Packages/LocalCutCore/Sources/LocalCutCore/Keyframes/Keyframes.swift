import Foundation
import CoreMedia

// MARK: - Keyframes

/// A cubic Bezier control handle for a keyframe segment.
///
/// `x` is normalised to the adjacent segment's duration. `y` stores the
/// absolute value at the control point; speed ramps clamp it to their supported
/// speed range before evaluation.
public struct KeyframeHandle: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// A single point in time with an associated value.
public struct Keyframe<T: Interpolatable>: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID
    public var time: CMTime
    public var value: T
    public var incomingHandle: KeyframeHandle?
    public var outgoingHandle: KeyframeHandle?

    public init(id: UUID = UUID(), time: CMTime, value: T,
                incomingHandle: KeyframeHandle? = nil,
                outgoingHandle: KeyframeHandle? = nil) {
        self.id = id
        self.time = time
        self.value = value
        self.incomingHandle = incomingHandle
        self.outgoingHandle = outgoingHandle
    }

    private enum CodingKeys: String, CodingKey {
        case id, time, value, incomingHandle, outgoingHandle
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        value = try c.decode(T.self, forKey: .value)
        incomingHandle = try c.decodeIfPresent(KeyframeHandle.self, forKey: .incomingHandle)
        outgoingHandle = try c.decodeIfPresent(KeyframeHandle.self, forKey: .outgoingHandle)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(incomingHandle, forKey: .incomingHandle)
        try c.encodeIfPresent(outgoingHandle, forKey: .outgoingHandle)
    }
}

/// A sorted collection of keyframes that interpolates linearly between them.
public struct Keyframed<T: Interpolatable>: Hashable, Codable, Sendable {
    public private(set) var keyframes: [Keyframe<T>]
    public var defaultValue: T

    public init(defaultValue: T) {
        self.keyframes = []
        self.defaultValue = defaultValue
    }

    public init(keyframes: [Keyframe<T>], defaultValue: T) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey { case keyframes, defaultValue }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([Keyframe<T>].self, forKey: .keyframes)
        let dv = try c.decode(T.self, forKey: .defaultValue)
        self.init(keyframes: raw, defaultValue: dv)
    }

    public var isAnimated: Bool { !keyframes.isEmpty }

    /// Linearly interpolates between the two surrounding keyframes.
    /// O(log n) via binary search for the lower bound.
    public func value(at time: CMTime) -> T {
        guard let first = keyframes.first, let last = keyframes.last else { return defaultValue }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }

        var lo = 0
        var hi = keyframes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keyframes[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        let before = keyframes[lo]
        let after = keyframes[lo + 1]
        let elapsed = (time - before.time).seconds
        let span = (after.time - before.time).seconds
        guard span > 0 else { return before.value }
        let t = Float(elapsed / span)
        return T.lerp(before.value, after.value, t: min(1, max(0, t)))
    }

    public mutating func addKeyframe(at time: CMTime, value: T,
                                     incomingHandle: KeyframeHandle? = nil,
                                     outgoingHandle: KeyframeHandle? = nil) {
        let kf = Keyframe(time: time, value: value,
                          incomingHandle: incomingHandle,
                          outgoingHandle: outgoingHandle)
        if let i = keyframes.firstIndex(where: { $0.time >= time }) {
            if keyframes[i].time == time {
                keyframes[i] = kf
            } else {
                keyframes.insert(kf, at: i)
            }
        } else {
            keyframes.append(kf)
        }
    }

    public mutating func removeKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    public mutating func removeKeyframe(at time: CMTime) {
        keyframes.removeAll { $0.time == time }
    }

    public mutating func updateKeyframe(id: UUID, time: CMTime? = nil, value: T? = nil) {
        guard keyframes.contains(where: { $0.id == id }) else { return }
        if let time {
            keyframes.removeAll { $0.id != id && $0.time == time }
        }
        guard let j = keyframes.firstIndex(where: { $0.id == id }) else { return }
        if let time { keyframes[j].time = time }
        if let value { keyframes[j].value = value }
        keyframes.sort { $0.time < $1.time }
    }

    public mutating func setIncomingHandle(_ handle: KeyframeHandle?, forKeyframe id: UUID) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].incomingHandle = handle
    }

    public mutating func setOutgoingHandle(_ handle: KeyframeHandle?, forKeyframe id: UUID) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].outgoingHandle = handle
    }
}

extension Keyframed where T == Float {
    /// Splits a clip-source-relative Bezier keyframe track into left/right
    /// tracks, rebasing the right half to a zero source origin. If the cut falls
    /// inside an eased segment, the cubic handles are split so the two resulting
    /// curves preserve the original shape instead of falling back to linear
    /// interpolation at the boundary.
    public func splitPreservingBezier(at cut: CMTime) -> (left: Keyframed<Float>, right: Keyframed<Float>) {
        guard isAnimated else { return (self, self) }

        let cut = cut.sanitized
        let boundary = bezierValue(at: cut)
        let exactMatch = keyframes.first { $0.time == cut }
        var leftKeys = keyframes.filter { $0.time < cut }
        var rightKeys: [Keyframe<Float>]

        if let exactMatch {
            leftKeys.append(exactMatch)
            rightKeys = [Keyframe<Float>(
                id: exactMatch.id,
                time: .zero,
                value: boundary,
                incomingHandle: exactMatch.incomingHandle,
                outgoingHandle: exactMatch.outgoingHandle)]
        } else {
            var leftBoundary = Keyframe<Float>(time: cut, value: boundary)
            var rightBoundary = Keyframe<Float>(time: .zero, value: boundary)
            var nextKeyframeID: UUID?
            var nextIncomingHandle: KeyframeHandle?

            if let previousIndex = keyframes.lastIndex(where: { $0.time < cut }),
               let nextIndex = keyframes.firstIndex(where: { $0.time > cut }),
               let handles = Self.splitHandles(before: keyframes[previousIndex],
                                               after: keyframes[nextIndex],
                                               at: cut) {
                if let leftIndex = leftKeys.lastIndex(where: { $0.id == keyframes[previousIndex].id }) {
                    leftKeys[leftIndex].outgoingHandle = handles.leftOutgoing
                }
                leftBoundary.incomingHandle = handles.leftIncoming
                rightBoundary.outgoingHandle = handles.rightOutgoing
                nextKeyframeID = keyframes[nextIndex].id
                nextIncomingHandle = handles.rightIncoming
            }

            leftKeys.append(leftBoundary)
            rightKeys = [rightBoundary]
            rightKeys.append(contentsOf: keyframes.compactMap { kf in
                let newTime = kf.time - cut
                guard newTime > .zero else { return nil }
                return Keyframe<Float>(
                    id: kf.id,
                    time: newTime,
                    value: kf.value,
                    incomingHandle: kf.incomingHandle,
                    outgoingHandle: kf.outgoingHandle)
            })

            if let nextKeyframeID,
               let nextIncomingHandle,
               let rightIndex = rightKeys.firstIndex(where: { $0.id == nextKeyframeID }) {
                rightKeys[rightIndex].incomingHandle = nextIncomingHandle
            }
        }

        return (Keyframed<Float>(keyframes: leftKeys, defaultValue: defaultValue),
                Keyframed<Float>(keyframes: rightKeys, defaultValue: defaultValue))
    }

    /// Evaluates a cubic Bezier value between surrounding keyframes. Existing
    /// keyframes without handles retain the same result as `value(at:)`.
    public func bezierValue(at time: CMTime) -> Float {
        guard let first = keyframes.first, let last = keyframes.last else { return defaultValue }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }

        var lo = 0
        var hi = keyframes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keyframes[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }

        let before = keyframes[lo]
        let after = keyframes[lo + 1]
        let elapsed = (time - before.time).seconds
        let span = (after.time - before.time).seconds
        guard span > 0 else { return before.value }
        let targetX = Float(min(1, max(0, elapsed / span)))
        return Self.cubicSegmentValue(before: before, after: after, x: targetX)
    }

    private static func cubicSegmentValue(before: Keyframe<Float>,
                                          after: Keyframe<Float>,
                                          x targetX: Float) -> Float {
        let delta = after.value - before.value
        let rawC1X = clampedUnit(before.outgoingHandle?.x ?? (1.0 / 3.0))
        let rawC2X = 1 - clampedUnit(after.incomingHandle?.x ?? (1.0 / 3.0))
        let c1X = min(rawC1X, rawC2X)
        let c2X = max(rawC1X, rawC2X)
        let c1Y = before.outgoingHandle?.y ?? before.value + delta / 3
        let c2Y = after.incomingHandle?.y ?? before.value + delta * 2 / 3

        var lower: Float = 0
        var upper: Float = 1
        var t: Float = targetX
        for _ in 0..<18 {
            t = (lower + upper) * 0.5
            let x = cubic(0, c1X, c2X, 1, t)
            if x < targetX {
                lower = t
            } else {
                upper = t
            }
        }
        return cubic(before.value, c1Y, c2Y, after.value, t)
    }

    private static func cubic(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let inverse = 1 - t
        return inverse * inverse * inverse * p0
            + 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2
            + t * t * t * p3
    }

    private struct SplitHandles {
        var leftOutgoing: KeyframeHandle
        var leftIncoming: KeyframeHandle
        var rightOutgoing: KeyframeHandle
        var rightIncoming: KeyframeHandle
    }

    private static func splitHandles(before: Keyframe<Float>,
                                     after: Keyframe<Float>,
                                     at cut: CMTime) -> SplitHandles? {
        let span = after.time - before.time
        guard span > .zero else { return nil }
        let targetX = Float(min(1, max(0, (cut - before.time).seconds / span.seconds)))
        guard targetX > 0, targetX < 1 else { return nil }

        let delta = after.value - before.value
        let rawC1X = clampedUnit(before.outgoingHandle?.x ?? (1.0 / 3.0))
        let rawC2X = 1 - clampedUnit(after.incomingHandle?.x ?? (1.0 / 3.0))
        let p0 = (x: Float(0), y: before.value)
        let p1 = (x: min(rawC1X, rawC2X), y: before.outgoingHandle?.y ?? before.value + delta / 3)
        let p2 = (x: max(rawC1X, rawC2X), y: after.incomingHandle?.y ?? before.value + delta * 2 / 3)
        let p3 = (x: Float(1), y: after.value)

        let t = cubicParameter(p0.x, p1.x, p2.x, p3.x, x: targetX)
        let a = lerp(p0, p1, t: t)
        let b = lerp(p1, p2, t: t)
        let c = lerp(p2, p3, t: t)
        let d = lerp(a, b, t: t)
        let e = lerp(b, c, t: t)
        let split = lerp(d, e, t: t)

        let leftSpan = max(split.x, Float.leastNonzeroMagnitude)
        let rightSpan = max(1 - split.x, Float.leastNonzeroMagnitude)
        return SplitHandles(
            leftOutgoing: KeyframeHandle(x: clampedUnit(a.x / leftSpan), y: a.y),
            leftIncoming: KeyframeHandle(x: clampedUnit((split.x - d.x) / leftSpan), y: d.y),
            rightOutgoing: KeyframeHandle(x: clampedUnit((e.x - split.x) / rightSpan), y: e.y),
            rightIncoming: KeyframeHandle(x: clampedUnit((1 - c.x) / rightSpan), y: c.y))
    }

    private static func cubicParameter(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, x targetX: Float) -> Float {
        var lower: Float = 0
        var upper: Float = 1
        var t: Float = targetX
        for _ in 0..<18 {
            t = (lower + upper) * 0.5
            let x = cubic(p0, p1, p2, p3, t)
            if x < targetX {
                lower = t
            } else {
                upper = t
            }
        }
        return t
    }

    private static func lerp(_ lhs: (x: Float, y: Float),
                             _ rhs: (x: Float, y: Float),
                             t: Float) -> (x: Float, y: Float) {
        (x: lhs.x + (rhs.x - lhs.x) * t,
         y: lhs.y + (rhs.y - lhs.y) * t)
    }

    private static func clampedUnit(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 / 3.0 }
        return min(1, max(0, value))
    }
}
