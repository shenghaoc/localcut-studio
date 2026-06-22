# Tasks: Keyframe System

> Status: **Implemented**. Codable uses `CMTimeCode` so the document representation matches the rest of the project.

## Implementation

- [x] **T1** Add `Interpolatable` protocol and `Float` conformance to `Models.swift`.
- [x] **T2** Add `Keyframe<T>` value type to `Models.swift`.
- [x] **T3** Add `Keyframed<T>` value type with binary-search evaluation to `Models.swift`.
- [x] **T4** Add mutation methods (`addKeyframe`, `removeKeyframe`, `updateKeyframe`); insert keeps the array sorted.
- [x] **T5** `Codable` support using `CMTimeCode` for `CMTime` so the document representation matches the rest of the project.
- [x] **T6** `Hashable` conformance so containing structs stay value-equal.

## Verification

- [x] **V1** Unit tests for `Keyframed<Float>` evaluation (empty, single, multiple keyframes).
- [x] **V2** Unit tests for boundary conditions (before first, after last keyframe).
- [x] **V3** Unit tests for mutation methods (insert order, remove, update).
- [x] **V4** Unit tests for `Codable` round-trip.
- [x] **V5** `xcodebuild` (Debug, macOS) green; no test count regression.
