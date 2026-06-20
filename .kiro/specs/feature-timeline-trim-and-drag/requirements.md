# Requirements: Timeline Trim & Drag

## R1 — Trim clip edges

- **R1.1** Drag a clip's left/right edge to change its in/out point on the timeline.
- **R1.2** Trimming the left edge adjusts both `sourceStart` and `timelineStart`; the right edge adjusts `duration` only.
- **R1.3** Trims are clamped to the source media bounds and to a minimum clip length (one frame).

## R2 — Move clips

- **R2.1** Drag a clip horizontally to change `timelineStart`; drag vertically to move it to another track of the same kind.
- **R2.2** Moves cannot create overlaps on a track: either block, ripple, or snap to the nearest gap (configurable; default snap).

## R3 — Snapping

- **R3.1** Edges snap to: the playhead, other clip boundaries, and `0`, within a pixel threshold.
- **R3.2** Snapping can be temporarily disabled with a modifier key during the drag.

## R4 — Feedback & integrity

- **R4.1** Live visual feedback during drag (ghost/position), using `translate`-style offset rather than full re-layout per event.
- **R4.2** The edit commits to the model on drag end and rebuilds once; no clip is dropped or duplicated.
- **R4.3** All operations remain undoable once persistence/undo lands.

## R5 — Verification

- **R5.1** Unit tests for trim/move math (bounds, min length, no-overlap resolution, snap targets).
- **R5.2** Smoke test: trim and reorder clips; preview reflects the new arrangement; export matches.
