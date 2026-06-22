# Tasks: Timeline Trim & Drag

> Status: **Implemented**. Shipped in [#4](https://github.com/shenghaoc/localcut-studio/pull/4) (PR title: "Timeline trim & drag (T1.1–T3.2)"). Code lives in `LocalCut Studio/EditorModel.swift` (`trimClip` / `moveClip` / `snapTargets` / `resolveSnap`) and `LocalCut Studio/TimelineView.swift` (hit zones + drag state). Tests in `LocalCut StudioTests/TrimAndDragTests.swift` and `LocalCut StudioTests/UndoRedoTests.swift`.

## Model ops

- [x] **T1.1** `trimClip(id:edge:to:)` — left adjusts `sourceStart` + `timelineStart`; right adjusts `duration`; clamp to source + min length.
- [x] **T1.2** `moveClip(id:toTrack:start:)` — same-kind tracks, non-overlap resolution.
- [x] **T1.3** `snapTargets()` / `resolveSnap(candidate:)` with pixel→seconds threshold and Option bypass.
- [x] **T1.4** Unit tests for trim/move/snap math and overlap resolution.

## Interaction

- [x] **T2.1** Edge vs. body hit zones + hover cursors on clip blocks.
- [x] **T2.2** Transient `dragMode` enum in `TimelineView` (`.trimmingLeft` / `.trimmingRight` / `.moving` cases carrying the candidate `CMTime`, not raw drag offset; the spec originally said "offset-based" but candidate-time captures the same idea with the snap result already folded in). No per-event model mutation — the model only sees the final values when `DragGesture.onEnded` fires.
- [x] **T2.3** Commit on drag end → single `rebuild()`.

## Verification

- [x] **T3.1** Unit-test coverage of the trim/move/snap math in `LocalCut StudioTests/TrimAndDragTests.swift` (left/right edge clamping, source-start clamping, move clamping to zero, cross-kind rejection, overlap resolution, snap-target enumeration and resolution) plus undo / redo integrity in `LocalCut StudioTests/UndoRedoTests.swift`. A full end-to-end smoke test that exports a trimmed/moved composition and verifies pixel parity with preview is not in the suite — the production parity is enforced by routing both preview and export through the same `CompositionBuilder.build` path that the unit tests target.
- [x] **T3.2** `xcodebuild` green; tests green with no count regression.
