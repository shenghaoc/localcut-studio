# Tasks: Timeline Trim & Drag

> Status: **Implemented**. Shipped in [#4](https://github.com/shenghaoc/localcut-studio/pull/4) (PR title: "Timeline trim & drag (T1.1–T3.2)"). Code lives in `LocalCut Studio/EditorModel.swift` (`trimClip` / `moveClip` / `snapTargets` / `resolveSnap`) and `LocalCut Studio/TimelineView.swift` (hit zones + drag state). Tests in `LocalCut StudioTests/TrimAndDragTests.swift` and `LocalCut StudioTests/UndoRedoTests.swift`.

## Model ops

- [x] **T1.1** `trimClip(id:edge:to:)` — left adjusts `sourceStart` + `timelineStart`; right adjusts `duration`; clamp to source + min length.
- [x] **T1.2** `moveClip(id:toTrack:start:)` — same-kind tracks, non-overlap resolution.
- [x] **T1.3** `snapTargets()` / `resolveSnap(candidate:)` with pixel→seconds threshold and Option bypass.
- [x] **T1.4** Unit tests for trim/move/snap math and overlap resolution.

## Interaction

- [x] **T2.1** Edge vs. body hit zones + hover cursors on clip blocks.
- [x] **T2.2** Transient `dragState` with `offset`-based live feedback (no per-event model mutation).
- [x] **T2.3** Commit on drag end → single `rebuild()`.

## Verification

- [x] **T3.1** Smoke test: trim both edges, move within and across tracks; preview + export reflect it.
- [x] **T3.2** `xcodebuild` green; tests green with no count regression.
