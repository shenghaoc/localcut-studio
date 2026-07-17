# Tasks: Keyframe System

> Status: **Implemented**. Codable uses `CMTimeCode` so the document representation matches the rest of the project.

## Implementation

- [x] **T1** Add `Interpolatable` plus `Float` and `Transform2D` conformances in `TimeExtensions.swift`.
- [x] **T2** Add `KeyframeHandle`, `Keyframe<T>`, and optional incoming/outgoing handles in `Keyframes.swift`.
- [x] **T3** Add `Keyframed<T>` with generic linear binary-search evaluation in `Keyframes.swift`.
- [x] **T4** Add mutation methods (`addKeyframe`, `removeKeyframe`, `updateKeyframe`); insert keeps the array sorted.
- [x] **T5** `Codable` support using `CMTimeCode` for `CMTime` so the document representation matches the rest of the project.
- [x] **T6** `Hashable` conformance so containing structs stay value-equal.
- [x] **T7** Inspector authoring controls for skin-smooth strength keyframes (add/update/remove at playhead, previous/next seek).
- [x] **T8** Scalar Bezier evaluation with absolute control values, handle mutation, and curve-preserving split support for speed ramps.
- [x] **T8.1** Clamp and finite-sanitize evaluated skin-smooth and look-effect
  curves at their model boundaries before inspector or compositor use.
- [x] **T9** `Transform2D` temporal Bezier evaluation with exact linear fallback, wired through clip/callout playhead state and the shared preview/export compositor.
- [x] **T10** Preserve speed, transform, skin-smooth, and look-strength Bezier
  curves across clip split, trim, and silence-removal source rebasing.

## Verification

- [x] **V1** Unit tests for `Keyframed<Float>` evaluation (empty, single, multiple keyframes).
- [x] **V2** Unit tests for boundary conditions (before first, after last keyframe).
- [x] **V3** Unit tests for mutation methods (insert order, remove, update).
- [x] **V4** Unit tests for `Codable` round-trip.
- [x] **V5** Model tests for skin-smooth keyframe authoring at playhead, undo, and previous/next seek.
- [x] **V6** `xcodebuild` (Debug, macOS) green; no test count regression.
- [x] **V7** Focused tests for scalar-handle behavior, transform temporal
  easing, handle-free linear fallback, clip/callout playhead evaluation, and
  curve continuity across split/trim/silence edits.
