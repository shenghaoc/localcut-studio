# Tasks: Keyframe System

> Status: **Proposed**. Infrastructure prerequisite for Phase 30, 32a, 35, 38, 43.

## Implementation

- [x] **T1** Add `Interpolatable` protocol and `Float` conformance to `Models.swift`
- [x] **T2** Add `Keyframe<T>` value type to `Models.swift`
- [x] **T3** Add `Keyframed<T>` value type with evaluation to `Models.swift`
- [x] **T4** Add mutation methods (`addKeyframe`, `removeKeyframe`, `updateKeyframe`)
- [x] **T5** Add `Codable` support with `CMTime` encoding
- [x] **T6** Add `Hashable` conformance

## Verification

- [x] **V1** Unit tests for `Keyframed<Float>` evaluation (empty, single, multiple keyframes)
- [x] **V2** Unit tests for boundary conditions (before first, after last keyframe)
- [x] **V3** Unit tests for mutation methods
- [x] **V4** Unit tests for `Codable` round-trip
- [x] **V5** `xcodebuild` (Debug, macOS) green
