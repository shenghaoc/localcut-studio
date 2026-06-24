import Foundation
import CoreMedia

// MARK: - Keyframes

/// A single point in time with an associated value.
public struct Keyframe<T: Interpolatable>: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID
    public var time: CMTime
    public var value: T

    public init(id: UUID = UUID(), time: CMTime, value: T) {
        self.id = id
        self.time = time
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case id, time, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        value = try c.decode(T.self, forKey: .value)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(value, forKey: .value)
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

    public mutating func addKeyframe(at time: CMTime, value: T) {
        let kf = Keyframe(time: time, value: value)
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
}
