# Design: Keyframe System

> Status: **Implemented**. Infrastructure prerequisite for Phase 30, 32a, 35, 38, 43.

## Goal

A generic keyframe animation system that allows any `Interpolatable` model value to be animated over time. The system must be:
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

A protocol for types that can be linearly interpolated. `Float`, `Transform2D`, and selected composite model values conform. `Transform2D` interpolation is component-wise.

### `KeyframeHandle` value type

```swift
struct KeyframeHandle: Hashable, Codable, Sendable {
    var x: Float
    var y: Float
}
```

`x` is normalised to the adjacent segment duration. For `Float` tracks, `y` is an absolute scalar control value. For `Transform2D` tracks, one pair of handles controls normalised temporal progress so every matrix component follows the same easing curve.

### `Keyframe<T: Interpolatable>` value type

```swift
struct Keyframe<T: Interpolatable>: Hashable, Codable, Identifiable {
    let id: UUID
    var time: CMTime
    var value: T
    var incomingHandle: KeyframeHandle?
    var outgoingHandle: KeyframeHandle?

    init(id: UUID = UUID(), time: CMTime, value: T,
         incomingHandle: KeyframeHandle? = nil,
         outgoingHandle: KeyframeHandle? = nil)
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

extension Keyframed where T == Float {
    func bezierValue(at time: CMTime) -> Float
}

extension Keyframed where T == Transform2D {
    func bezierValue(at time: CMTime) -> Transform2D
}
```

Evaluation logic:
1. If `keyframes` is empty, return `defaultValue`
2. If `time` ≤ first keyframe's time, return first keyframe's value
3. If `time` ≥ last keyframe's time, return last keyframe's value
4. Otherwise, find the two surrounding keyframes via binary search and linearly interpolate

The generic `value(at:)` contract stays linear. The scalar overload evaluates cubic Bezier control values and is used by speed, skin-smooth, and look-strength curves. Each bounded effect sanitizes the evaluated result to its valid finite parameter range before UI or render use, so handle overshoot cannot feed an invalid kernel value. The `Transform2D` overload solves the handles' x curve for time, clamps finite y controls to normalised `0...1` temporal progress, evaluates that progress, then component-linearly interpolates the transform. A transform segment with no handles takes the generic linear result exactly; invalid non-finite temporal y controls fall back to linear.

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

Effects that support scalar keyframing use `Keyframed<Float>` for their animatable parameters. Screencast zoom/pan and callout animation use `Keyframed<Transform2D>`. The compositor evaluates tracks at clip-local render time and passes the result to the filter/compositor node, so moving a clip on the timeline does not change the look of its internal animation. Transform playhead inspection and the shared preview/export compositor both call `bezierValue(at:)`.

Clip splits, head/tail trims, and accepted silence cuts subdivide or re-anchor
the same source-local curves. Boundary keyframes and subdivided handles retain
the original motion on both surviving sides; formerly unused end handles are
cleared when a new constant extension would otherwise activate them.

The Phase 32a inspector keeps the static default-strength slider and adds a minimal authoring surface
for skin-smooth strength: add/update at the selected clip's local playhead time, remove at playhead,
and previous/next keyframe seek. The controls route through `EditorModel` so undo, render-cache
invalidation, and preview rebuilds stay in the same path as other skin-smooth edits.

## Codable representation

`CMTime` is encoded via the existing `CMTimeCode` rational pair (`value`/`timescale`) defined in `TimeExtensions.swift`, so keyframed parameters round-trip losslessly through the project document and stay schema-compatible with clip / transition times. Handles are optional for backward-compatible decoding of handle-free tracks.

## Performance Considerations

- Binary search for O(log n) evaluation
- Keyframes sorted on insert to avoid repeated sorting
- No caching needed for typical use cases (< 100 keyframes per parameter)

## Trade-offs

- The generic evaluator remains linear; Bezier evaluation is specialised for scalar control values and shared temporal easing of `Transform2D` components.
- A single monotonic temporal curve drives all six `Transform2D` components. This keeps authored motion coherent and split-safe but does not provide separate per-component curves or transform overshoot.
- Cubic x controls are ordered into a monotonic time curve, making deterministic binary inversion possible.

## Non-goals

- A universal Bezier control-value representation for arbitrary `Interpolatable` types
- Separate per-component transform easing curves
- Catmull-Rom interpolation curves
- Velocity-based interpolation
- Keyframe snapping/quantization
- Timeline keyframe lanes
- Generic authoring UI for every keyframable parameter
