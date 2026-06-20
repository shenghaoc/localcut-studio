# Requirements: Transitions

## R1 — Transition model

- **R1.1** A transition sits between two adjacent clips on the same video track, with a duration and a type.
- **R1.2** v1 types: cross-dissolve and a directional wipe.
- **R1.3** Transition duration is bounded by the available overlap of the two clips (cannot exceed either clip's length).

## R2 — Render path

- **R2.1** Transitions render in the shared composition path (preview = export).
- **R2.2** Cross-dissolve uses opacity ramps on overlapping layer instructions; the wipe uses a Core Image transition filter in the custom compositor.
- **R2.3** During a transition the two clips overlap in time on the timeline by the transition duration.

## R3 — UI

- **R3.1** Add a transition at a cut (between selected adjacent clips) via toolbar/menu/context menu.
- **R3.2** A transition is selectable on the timeline (rendered at the cut) with an inspector to set type + duration.
- **R3.3** Removing a transition restores the plain cut.

## R4 — Integrity

- **R4.1** Adjusting a transition never drops a clip or produces negative durations.
- **R4.2** Default duration is sensible (e.g. 0.5s) and clamped to overlap availability.

## R5 — Verification

- **R5.1** Unit tests for overlap/duration clamping and the resulting time ranges.
- **R5.2** Smoke test: add a cross-dissolve and a wipe; scrub across each; export matches preview.
