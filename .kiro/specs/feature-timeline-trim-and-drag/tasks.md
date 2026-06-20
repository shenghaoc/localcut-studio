# Tasks: Timeline Trim & Drag

> Status: **Proposed**.

## Model ops

- [ ] **T1.1** `trimClip(id:edge:to:)` — left adjusts `sourceStart` + `timelineStart`; right adjusts `duration`; clamp to source + min length.
- [ ] **T1.2** `moveClip(id:toTrack:start:)` — same-kind tracks, non-overlap resolution.
- [ ] **T1.3** `snapTargets()` / `resolveSnap(candidate:)` with pixel→seconds threshold and Option bypass.
- [ ] **T1.4** Unit tests for trim/move/snap math and overlap resolution.

## Interaction

- [ ] **T2.1** Edge vs. body hit zones + hover cursors on clip blocks.
- [ ] **T2.2** Transient `dragState` with `offset`-based live feedback (no per-event model mutation).
- [ ] **T2.3** Commit on drag end → single `rebuild()`.

## Verification

- [ ] **T3.1** Smoke test: trim both edges, move within and across tracks; preview + export reflect it.
- [ ] **T3.2** `xcodebuild` green; tests green with no count regression.
