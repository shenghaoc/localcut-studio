# Tasks: Transitions

> Status: **Proposed**.

## Model & engine

- [ ] **T1.1** `Transition` type (type + duration) attached at a cut; derived overlap from neighbours.
- [ ] **T1.2** Builder: overlap placement + opacity-ramp instruction for cross-dissolve.
- [ ] **T1.3** Wipe via `EffectCompositor` transition blend over the overlap interval.
- [ ] **T1.4** Duration clamping to available overlap; unit tests for time ranges.

## UI

- [ ] **T2.1** Add-transition action (toolbar/menu/context) at a selected cut.
- [ ] **T2.2** Selectable transition glyph at the cut + inspector (type, duration); delete restores the cut.

## Verification

- [ ] **T3.1** Smoke test: cross-dissolve + wipe scrub correctly; export matches preview.
- [ ] **T3.2** `xcodebuild` green; tests green with no count regression.
