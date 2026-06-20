# Design: Timeline Trim & Drag

> Status: **Proposed**.

## Approach

Add gesture handling to `TimelineView` clip blocks: edge-zone drags trim, body drags move. During a drag, keep transient state (a `dragState` enum: `.trimmingLeft/.trimmingRight/.moving` with a candidate `CMTime`) and render the clip at the candidate position via `offset`, without mutating the model. On drag end, resolve snapping + overlap rules and apply one mutation through a new `EditorModel.applyDrag(...)`, which rebuilds once.

## Pieces

- **Hit zones**: leading/trailing ~8pt of a clip = trim; the rest = move. Cursor feedback via `.onHover`.
- **Snapping**: a `snapTargets()` helper collects playhead + all clip boundaries + 0; `resolveSnap(candidate:)` returns the nearest within threshold (in seconds, derived from a pixel threshold ÷ `pixelsPerSecond`). Modifier key (Option) bypasses.
- **Overlap policy**: `Track.insert(clip:resolving:)` returns a non-overlapping placement (snap-to-gap default; ripple optional later).
- **Model ops** (`EditorModel`): `trimClip(id:edge:to:)`, `moveClip(id:toTrack:start:)` — pure `CMTime` math, clamped to source bounds and min length.

## Performance

Use transient `offset`-based rendering during the drag (compositor-friendly), mutate + `rebuild()` only on commit (see `.jules/bolt.md`).

## Risks

- Cross-track moves must preserve clip kind (video↔video, audio↔audio).
- Snapping math must be frame-accurate at the commit step even if the visual drag is pixel-based.
