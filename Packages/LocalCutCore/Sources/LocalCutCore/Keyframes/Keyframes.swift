import Foundation
import CoreMedia

// MARK: - Keyframes

/// A cubic Bezier control handle for a keyframe segment.
///
/// `x` is normalised to the adjacent segment's duration. For scalar keyframes,
/// `y` stores the absolute value at the control point. For `Transform2D`
/// keyframes, `y` stores normalised temporal progress, allowing one easing
/// curve to drive every transform component consistently.
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

/// A sorted collection of keyframes. The generic evaluator interpolates
/// linearly; supported value types can also expose specialised Bezier
/// evaluators that honour stored handles.
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

    /// Returns a copy with keyframes re-anchored after trimming `offset`
    /// from the head. The returned track starts with the value at the split
    /// boundary and drops keyframes that would otherwise become negative.
    public func shifted(by offset: CMTime) -> Keyframed<T> {
        guard offset != .zero, !keyframes.isEmpty else { return self }
        let anchor: Keyframe<T>
        if let exact = keyframes.first(where: { $0.time == offset }) {
            anchor = Keyframe(
                id: exact.id,
                time: .zero,
                value: exact.value,
                incomingHandle: nil,
                outgoingHandle: exact.outgoingHandle)
        } else {
            anchor = Keyframe(time: .zero, value: value(at: offset))
        }
        let shifted = keyframes.compactMap { kf -> Keyframe<T>? in
            guard kf.time > offset else { return nil }
            return Keyframe(
                id: kf.id,
                time: kf.time - offset,
                value: kf.value,
                incomingHandle: kf.incomingHandle,
                outgoingHandle: kf.outgoingHandle)
        }
        return Keyframed(keyframes: [anchor] + shifted, defaultValue: anchor.value)
    }

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
        if let i = keyframes.firstIndex(where: { $0.time >= time }) {
            if keyframes[i].time == time {
                // Preserve existing bezier handles when updating value at the
                // same time — the caller passes nil handles for a value-only
                // update (e.g. "Update" button), and destroying user-authored
                // ease curves would be data loss.
                keyframes[i].value = value
                if let incomingHandle { keyframes[i].incomingHandle = incomingHandle }
                if let outgoingHandle { keyframes[i].outgoingHandle = outgoingHandle }
            } else {
                let kf = Keyframe(time: time, value: value,
                                  incomingHandle: incomingHandle,
                                  outgoingHandle: outgoingHandle)
                keyframes.insert(kf, at: i)
            }
        } else {
            let kf = Keyframe(time: time, value: value,
                              incomingHandle: incomingHandle,
                              outgoingHandle: outgoingHandle)
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
        let exactMatch = keyframes.first { $0.time == cut }
        let boundary = exactMatch?.value ?? bezierValue(at: cut)
        var leftKeys = keyframes.filter { $0.time < cut }
        var rightKeys: [Keyframe<Float>]

        if let exactMatch {
            leftKeys.append(exactMatch)
            rightKeys = [Keyframe<Float>(
                id: exactMatch.id,
                time: .zero,
                value: boundary,
                incomingHandle: nil,
                outgoingHandle: exactMatch.outgoingHandle)]
            rightKeys.append(contentsOf: keyframes.compactMap { keyframe in
                guard keyframe.time > cut else { return nil }
                return Keyframe<Float>(
                    id: keyframe.id,
                    time: keyframe.time - cut,
                    value: keyframe.value,
                    incomingHandle: keyframe.incomingHandle,
                    outgoingHandle: keyframe.outgoingHandle)
            })
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

            if let firstTime = keyframes.first?.time, cut < firstTime, rightKeys.count > 1 {
                rightKeys[1].incomingHandle = nil
            }
            if let lastTime = keyframes.last?.time, cut > lastTime, leftKeys.count > 1 {
                leftKeys[leftKeys.count - 2].outgoingHandle = nil
            }
        }

        return (Keyframed<Float>(keyframes: leftKeys, defaultValue: defaultValue),
                Keyframed<Float>(keyframes: rightKeys, defaultValue: boundary))
    }

    /// Re-anchors a scalar Bezier track after moving its clip-source origin.
    /// Positive offsets split the active cubic so the surviving right-hand
    /// curve is unchanged. Negative offsets prepend a constant interval before
    /// the original source origin.
    public func shiftedPreservingBezier(by offset: CMTime) -> Keyframed<Float> {
        guard offset != .zero, isAnimated else { return self }
        if offset > .zero {
            return splitPreservingBezier(at: offset).right
        }

        let anchorValue = bezierValue(at: offset)
        var shiftedKeys = keyframes.map { keyframe in
            Keyframe<Float>(
                id: keyframe.id,
                time: keyframe.time - offset,
                value: keyframe.value,
                incomingHandle: keyframe.incomingHandle,
                outgoingHandle: keyframe.outgoingHandle)
        }
        // The old first keyframe now follows a newly inserted constant span.
        // Its formerly unused incoming handle must not bend that span.
        if !shiftedKeys.isEmpty {
            shiftedKeys[0].incomingHandle = nil
        }
        let anchor = Keyframe<Float>(time: .zero, value: anchorValue)
        return Keyframed<Float>(
            keyframes: [anchor] + shiftedKeys,
            defaultValue: anchorValue)
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
        if before.time == time { return before.value }
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

extension Keyframed where T == Transform2D {
    /// Splits a transform track at a clip-source-local cut. When the cut lies
    /// inside an eased segment, both the temporal x curve and its normalised
    /// progress y curve are subdivided so each half reproduces the original
    /// transform motion exactly.
    public func splitPreservingBezier(
        at cut: CMTime
    ) -> (left: Keyframed<Transform2D>, right: Keyframed<Transform2D>) {
        guard isAnimated else { return (self, self) }

        let cut = cut.sanitized
        let exactMatch = keyframes.first { $0.time == cut }
        let boundary = exactMatch?.value ?? bezierValue(at: cut)
        var leftKeys = keyframes.filter { $0.time < cut }
        var rightKeys: [Keyframe<Transform2D>]

        if let exactMatch {
            leftKeys.append(exactMatch)
            rightKeys = [Keyframe<Transform2D>(
                id: exactMatch.id,
                time: .zero,
                value: boundary,
                incomingHandle: nil,
                outgoingHandle: exactMatch.outgoingHandle)]
            rightKeys.append(contentsOf: keyframes.compactMap { keyframe in
                guard keyframe.time > cut else { return nil }
                return Keyframe<Transform2D>(
                    id: keyframe.id,
                    time: keyframe.time - cut,
                    value: keyframe.value,
                    incomingHandle: keyframe.incomingHandle,
                    outgoingHandle: keyframe.outgoingHandle)
            })
        } else {
            var leftBoundary = Keyframe<Transform2D>(time: cut, value: boundary)
            var rightBoundary = Keyframe<Transform2D>(time: .zero, value: boundary)
            var nextKeyframeID: UUID?
            var nextIncomingHandle: KeyframeHandle?
            var usesLinearFallback = false

            if let previousIndex = keyframes.lastIndex(where: { $0.time < cut }),
               let nextIndex = keyframes.firstIndex(where: { $0.time > cut }) {
                nextKeyframeID = keyframes[nextIndex].id
                if let handles = Self.splitTemporalHandles(
                    before: keyframes[previousIndex],
                    after: keyframes[nextIndex],
                    at: cut) {
                    if let leftIndex = leftKeys.lastIndex(where: { $0.id == keyframes[previousIndex].id }) {
                        leftKeys[leftIndex].outgoingHandle = handles.leftOutgoing
                    }
                    leftBoundary.incomingHandle = handles.leftIncoming
                    rightBoundary.outgoingHandle = handles.rightOutgoing
                    nextIncomingHandle = handles.rightIncoming
                } else {
                    // A malformed temporal y handle makes the unsplit evaluator
                    // fall back to linear interpolation. Clear both endpoint
                    // handles so neither new half accidentally becomes eased.
                    if let leftIndex = leftKeys.lastIndex(where: { $0.id == keyframes[previousIndex].id }) {
                        leftKeys[leftIndex].outgoingHandle = nil
                    }
                    usesLinearFallback = true
                }
            }

            leftKeys.append(leftBoundary)
            rightKeys = [rightBoundary]
            rightKeys.append(contentsOf: keyframes.compactMap { keyframe in
                guard keyframe.time > cut else { return nil }
                return Keyframe<Transform2D>(
                    id: keyframe.id,
                    time: keyframe.time - cut,
                    value: keyframe.value,
                    incomingHandle: keyframe.incomingHandle,
                    outgoingHandle: keyframe.outgoingHandle)
            })

            if let nextKeyframeID,
               let rightIndex = rightKeys.firstIndex(where: { $0.id == nextKeyframeID }) {
                rightKeys[rightIndex].incomingHandle = usesLinearFallback ? nil : nextIncomingHandle
            } else if rightKeys.count > 1 {
                // A handle that was unused before the original first keyframe
                // must not become active after inserting a boundary anchor.
                rightKeys[1].incomingHandle = nil
            }

            if let lastTime = keyframes.last?.time, cut > lastTime, leftKeys.count > 1 {
                leftKeys[leftKeys.count - 2].outgoingHandle = nil
            }
        }

        return (
            Keyframed<Transform2D>(keyframes: leftKeys, defaultValue: defaultValue),
            Keyframed<Transform2D>(keyframes: rightKeys, defaultValue: boundary))
    }

    /// Re-anchors a transform track after moving its clip-source origin.
    /// Positive offsets retain the subdivided right-hand easing curve; negative
    /// offsets prepend a constant interval before the old source origin.
    public func shiftedPreservingBezier(by offset: CMTime) -> Keyframed<Transform2D> {
        guard offset != .zero, isAnimated else { return self }
        if offset > .zero {
            return splitPreservingBezier(at: offset).right
        }

        let anchorValue = bezierValue(at: offset)
        var shiftedKeys = keyframes.map { keyframe in
            Keyframe<Transform2D>(
                id: keyframe.id,
                time: keyframe.time - offset,
                value: keyframe.value,
                incomingHandle: keyframe.incomingHandle,
                outgoingHandle: keyframe.outgoingHandle)
        }
        if !shiftedKeys.isEmpty {
            shiftedKeys[0].incomingHandle = nil
        }
        let anchor = Keyframe<Transform2D>(time: .zero, value: anchorValue)
        return Keyframed<Transform2D>(
            keyframes: [anchor] + shiftedKeys,
            defaultValue: anchorValue)
    }

    /// Evaluates the transform using the surrounding keyframes' handles as a
    /// temporal Bezier easing curve. The handle `y` values are normalised
    /// progress controls; the resulting progress is applied uniformly to all
    /// six transform components. Tracks without handles remain exactly linear.
    public func bezierValue(at time: CMTime) -> Transform2D {
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
        if before.time == time { return before.value }
        let after = keyframes[lo + 1]
        let elapsed = (time - before.time).seconds
        let span = (after.time - before.time).seconds
        guard span > 0 else { return before.value }

        let linearProgress = Float(min(1, max(0, elapsed / span)))
        guard before.outgoingHandle != nil || after.incomingHandle != nil,
              let easedProgress = Self.temporalBezierProgress(
                from: before,
                to: after,
                at: linearProgress) else {
            return Transform2D.lerp(before.value, after.value, t: linearProgress)
        }
        return Transform2D.lerp(before.value, after.value, t: easedProgress)
    }

    private static func temporalBezierProgress(
        from before: Keyframe<Transform2D>,
        to after: Keyframe<Transform2D>,
        at targetX: Float
    ) -> Float? {
        guard let c1Y = clampedTemporalY(before.outgoingHandle?.y ?? (1.0 / 3.0)),
              let c2Y = clampedTemporalY(after.incomingHandle?.y ?? (2.0 / 3.0))
        else { return nil }

        let rawC1X = clampedTemporalX(before.outgoingHandle?.x ?? (1.0 / 3.0))
        let rawC2X = 1 - clampedTemporalX(after.incomingHandle?.x ?? (1.0 / 3.0))
        let c1X = min(rawC1X, rawC2X)
        let c2X = max(rawC1X, rawC2X)

        var lower: Float = 0
        var upper: Float = 1
        var parameter = targetX
        for _ in 0..<18 {
            parameter = (lower + upper) * 0.5
            let x = temporalCubic(0, c1X, c2X, 1, parameter)
            if x < targetX {
                lower = parameter
            } else {
                upper = parameter
            }
        }

        let progress = temporalCubic(0, c1Y, c2Y, 1, parameter)
        return progress.isFinite ? progress : nil
    }

    private struct TemporalSplitHandles {
        var leftOutgoing: KeyframeHandle
        var leftIncoming: KeyframeHandle
        var rightOutgoing: KeyframeHandle
        var rightIncoming: KeyframeHandle
    }

    private static func splitTemporalHandles(
        before: Keyframe<Transform2D>,
        after: Keyframe<Transform2D>,
        at cut: CMTime
    ) -> TemporalSplitHandles? {
        let span = after.time - before.time
        guard span > .zero else { return nil }
        let targetX = Float(min(1, max(0, (cut - before.time).seconds / span.seconds)))
        guard targetX > 0, targetX < 1 else { return nil }

        guard let c1Y = clampedTemporalY(before.outgoingHandle?.y ?? (1.0 / 3.0)),
              let c2Y = clampedTemporalY(after.incomingHandle?.y ?? (2.0 / 3.0))
        else { return nil }
        let rawC1X = clampedTemporalX(before.outgoingHandle?.x ?? (1.0 / 3.0))
        let rawC2X = 1 - clampedTemporalX(after.incomingHandle?.x ?? (1.0 / 3.0))

        let p0 = (x: Float(0), y: Float(0))
        let p1 = (x: min(rawC1X, rawC2X), y: c1Y)
        let p2 = (x: max(rawC1X, rawC2X), y: c2Y)
        let p3 = (x: Float(1), y: Float(1))
        let parameter = temporalCubicParameter(
            p0.x, p1.x, p2.x, p3.x, x: targetX)
        let a = temporalPointLerp(p0, p1, t: parameter)
        let b = temporalPointLerp(p1, p2, t: parameter)
        let c = temporalPointLerp(p2, p3, t: parameter)
        let d = temporalPointLerp(a, b, t: parameter)
        let e = temporalPointLerp(b, c, t: parameter)
        let split = temporalPointLerp(d, e, t: parameter)

        let leftXSpan = max(split.x, Float.leastNonzeroMagnitude)
        let rightXSpan = max(1 - split.x, Float.leastNonzeroMagnitude)
        // A flat endpoint can make one progress span exactly zero. That half
        // also has identical endpoint transforms, so a tiny denominator keeps
        // the normalized handles finite without changing its rendered value.
        let leftYSpan = max(split.y, Float.leastNonzeroMagnitude)
        let rightYSpan = max(1 - split.y, Float.leastNonzeroMagnitude)

        let handles = TemporalSplitHandles(
            leftOutgoing: KeyframeHandle(
                x: clampedTemporalX(a.x / leftXSpan),
                y: clampedTemporalY(a.y / leftYSpan) ?? (1.0 / 3.0)),
            leftIncoming: KeyframeHandle(
                x: clampedTemporalX((split.x - d.x) / leftXSpan),
                y: clampedTemporalY(d.y / leftYSpan) ?? (2.0 / 3.0)),
            rightOutgoing: KeyframeHandle(
                x: clampedTemporalX((e.x - split.x) / rightXSpan),
                y: clampedTemporalY((e.y - split.y) / rightYSpan) ?? (1.0 / 3.0)),
            rightIncoming: KeyframeHandle(
                x: clampedTemporalX((1 - c.x) / rightXSpan),
                y: clampedTemporalY((c.y - split.y) / rightYSpan) ?? (2.0 / 3.0)))
        let values = [
            handles.leftOutgoing.y,
            handles.leftIncoming.y,
            handles.rightOutgoing.y,
            handles.rightIncoming.y,
        ]
        return values.allSatisfy(\.isFinite) ? handles : nil
    }

    private static func temporalCubicParameter(
        _ p0: Float,
        _ p1: Float,
        _ p2: Float,
        _ p3: Float,
        x targetX: Float
    ) -> Float {
        var lower: Float = 0
        var upper: Float = 1
        var parameter = targetX
        for _ in 0..<18 {
            parameter = (lower + upper) * 0.5
            let x = temporalCubic(p0, p1, p2, p3, parameter)
            if x < targetX {
                lower = parameter
            } else {
                upper = parameter
            }
        }
        return parameter
    }

    private static func temporalPointLerp(
        _ lhs: (x: Float, y: Float),
        _ rhs: (x: Float, y: Float),
        t: Float
    ) -> (x: Float, y: Float) {
        (x: lhs.x + (rhs.x - lhs.x) * t,
         y: lhs.y + (rhs.y - lhs.y) * t)
    }

    private static func temporalCubic(
        _ p0: Float,
        _ p1: Float,
        _ p2: Float,
        _ p3: Float,
        _ t: Float
    ) -> Float {
        let inverse = 1 - t
        return inverse * inverse * inverse * p0
            + 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2
            + t * t * t * p3
    }

    private static func clampedTemporalX(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 / 3.0 }
        return min(1, max(0, value))
    }

    private static func clampedTemporalY(_ value: Float) -> Float? {
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
