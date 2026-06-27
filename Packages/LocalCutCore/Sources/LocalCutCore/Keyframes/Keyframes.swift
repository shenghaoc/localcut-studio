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

    private static func clampedUnit(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 / 3.0 }
        return min(1, max(0, value))
    }
}
