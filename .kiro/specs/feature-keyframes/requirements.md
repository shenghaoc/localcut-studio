# Requirements: Keyframe System

> Status: **Proposed**.

## R1 — Core Types

- **R1.1** `Interpolatable` protocol with `static func lerp(_:_:t:)` for linear interpolation.
- **R1.2** `Float` conforms to `Interpolatable`.
- **R1.3** `Keyframe<T: Interpolatable>` value type with `id: UUID`, `time: CMTime`, `value: T`.
- **R1.4** `Keyframed<T: Interpolatable>` value type with `keyframes: [Keyframe<T>]` and `defaultValue: T`.

## R2 — Evaluation

- **R2.1** `Keyframed.value(at:)` returns the interpolated value at the given time.
- **R2.2** Empty keyframes returns `defaultValue` for all times.
- **R2.3** Times before the first keyframe return the first keyframe's value.
- **R2.4** Times after the last keyframe return the last keyframe's value.
- **R2.5** Binary search for O(log n) evaluation.

## R3 — Mutation

- **R3.1** `addKeyframe(at:value:)` inserts a keyframe, maintaining sorted order.
- **R3.2** `removeKeyframe(id:)` removes a keyframe by ID.
- **R3.3** `updateKeyframe(id:time:value:)` updates an existing keyframe's time and/or value.

## R4 — Codable

- **R4.1** `Keyframe` and `Keyframed` conform to `Codable`.
- **R4.2** `CMTime` encoded as `{value: Int64, timescale: CMTimeScale}`.
- **R4.3** Round-trip encoding preserves all data.

## R5 — Hashable

- **R5.1** `Keyframe` and `Keyframed` conform to `Hashable`.
- **R5.2** Two `Keyframed` values are equal iff their keyframes and default values are equal.
