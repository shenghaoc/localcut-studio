# Design: Keyframe System

> Status: **Proposed**. Infrastructure prerequisite for Phase 30, 32a, 35, 38, 43.

## Goal

A generic keyframe animation system that allows any `Float`-based parameter to be animated over time. The system must be:
- **Type-safe**: `Keyframed<T>` wraps a value that can be interpolated
- **Codable**: Persisted in the project document
- **Efficient**: O(log n) lookup via binary search
- **Deterministic**: Same inputs always produce the same output

## Core Types

### `Interpolatable` protocol

```swift
protocol Interpolatable: Hashable, Codable {
    static func lerp(_ a: Self, _ b: Self, t: Float) -> Self
}
```

A protocol for types that can be linearly interpolated. `Float` conforms trivially.

### `Keyframe<T: Interpolatable>` value type

```swift
struct Keyframe<T: Interpolatable>: Hashable, Codable, Identifiable {
    let id: UUID
    var time: CMTime
    var value: T

    init(id: UUID = UUID(), time: CMTime, value: T)
}
```

A single point in time with an associated value. The `id` enables stable identity in the inspector UI.

### `Keyframed<T: Interpolatable>` value type

```swift
struct Keyframed<T: Interpolatable>: Hashable, Codable {
    var keyframes: [Keyframe<T>]
    var defaultValue: T

    init(defaultValue: T)
    init(keyframes: [Keyframe<T>], defaultValue: T)
}
```

A collection of keyframes sorted by time. If `keyframes` is empty, `defaultValue` is returned for all times.

### Evaluation

```swift
extension Keyframed {
    func value(at time: CMTime) -> T
}
```

Evaluation logic:
1. If `keyframes` is empty, return `defaultValue`
2. If `time` ≤ first keyframe's time, return first keyframe's value
3. If `time` ≥ last keyframe's time, return last keyframe's value
4. Otherwise, find the two surrounding keyframes via binary search and linearly interpolate

### Convenience

```swift
extension Keyframed {
    var isAnimated: Bool { !keyframes.isEmpty }

    mutating func addKeyframe(at time: CMTime, value: T)
    mutating func removeKeyframe(id: UUID)
    mutating func updateKeyframe(id: UUID, time: CMTime?, value: T?)
}
```

## Integration with Effect Chain

Effects that support keyframing use `Keyframed<Float>` for their animatable parameters. The compositor evaluates the keyframed value at the current composition time and passes it to the CIFilter.

## Performance Considerations

- Binary search for O(log n) evaluation
- Keyframes sorted on insert to avoid repeated sorting
- No caching needed for typical use cases (< 100 keyframes per parameter)

## Trade-offs

- Linear interpolation only (no Catmull-Rom or bezier curves) — sufficient for most NLE parameters
- Single-value keyframes only (no multi-dimensional like position) — can be extended later
- No easing functions — can be added as a future enhancement

## Non-goals

- Bezier/Catmull-Rom interpolation curves
- Multi-dimensional keyframes (position, scale, etc.)
- Velocity-based interpolation
- Keyframe snapping/quantization
