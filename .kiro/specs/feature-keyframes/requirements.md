# Requirements: Keyframe System

> Status: **Implemented**.

## R1 — Core Types

- **R1.1** `Interpolatable` protocol with `static func lerp(_:_:t:)` for linear interpolation.
- **R1.2** `Float` and `Transform2D` conform to `Interpolatable`; other model values may opt in for generic linear interpolation.
- **R1.3** `Keyframe<T: Interpolatable>` value type with `id: UUID`, `time: CMTime`, `value: T`, and optional incoming/outgoing `KeyframeHandle` values.
- **R1.4** `Keyframed<T: Interpolatable>` value type with `keyframes: [Keyframe<T>]` and `defaultValue: T`.

## R2 — Evaluation

- **R2.1** Generic `Keyframed.value(at:)` returns the linearly interpolated value at the given time.
- **R2.2** Empty keyframes returns `defaultValue` for all times.
- **R2.3** Times before the first keyframe return the first keyframe's value.
- **R2.4** Times after the last keyframe return the last keyframe's value.
- **R2.5** Binary search for O(log n) evaluation.
- **R2.6** `Keyframed<Float>.bezierValue(at:)` honours scalar handles whose `y` coordinates are absolute control values; missing handles retain the existing linear curve, and bounded effect consumers sanitize evaluated values to their finite supported ranges.
- **R2.7** `Keyframed<Transform2D>.bezierValue(at:)` treats finite handle `y` coordinates as normalised temporal progress clamped to `0...1`, applies that progress to every transform component, and falls back exactly to linear interpolation when a segment has no handles or has non-finite temporal controls.

## R3 — Mutation

- **R3.1** `addKeyframe(at:value:)` inserts a keyframe, maintaining sorted order.
- **R3.2** `removeKeyframe(id:)` removes a keyframe by ID.
- **R3.3** `updateKeyframe(id:time:value:)` updates an existing keyframe's time and/or value.
- **R3.4** Incoming and outgoing handles can be set independently without replacing the keyframe value.
- **R3.5** Splitting, head/tail trimming, and silence removal preserve scalar and
  transform Bezier motion in clip-source-local time, including constant motion
  before the first and after the last authored keyframe.

## R4 — Codable

- **R4.1** `Keyframe` and `Keyframed` conform to `Codable`.
- **R4.2** `CMTime` encoded as `{value: Int64, timescale: CMTimeScale}`.
- **R4.3** Round-trip encoding preserves values, times, identities, and optional Bezier handles.

## R5 — Hashable

- **R5.1** `Keyframe` and `Keyframed` conform to `Hashable`.
- **R5.2** Two `Keyframed` values are equal iff their keyframes and default values are equal.

## R6 — Minimal Authoring Surface

- **R6.1** The inspector can add or update a skin-smooth strength keyframe at the selected clip's playhead.
- **R6.2** The inspector can remove the skin-smooth strength keyframe at the playhead.
- **R6.3** Previous/next controls seek to adjacent skin-smooth strength keyframes for the selected clip.
- **R6.4** Clip and callout transform controls can add, update, remove, edit, and seek adjacent `Transform2D` keyframes; playhead, preview, and export evaluation share the temporal Bezier behavior.
