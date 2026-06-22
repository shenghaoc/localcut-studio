# Tasks: Transitions

> Status: **Implemented**. Shipped in [#5](https://github.com/shenghaoc/localcut-studio/pull/5) (PR title: "Transitions: cross-dissolve & wipe (T1.1–T3.2)"). Code lives in `LocalCut Studio/TransitionLayout.swift`, `LocalCut Studio/CompositionBuilder.swift`, `LocalCut Studio/EffectCompositor.swift`, with `Transition` + `TransitionType` types in `LocalCut Studio/Models.swift` and tests in `LocalCut StudioTests/TransitionsTests.swift` + `LocalCut StudioTests/TransitionsIntegrationTests.swift`.

## Model & engine

- [x] **T1.1** `Transition` type (type + duration) attached at a cut; derived overlap from neighbours.
- [x] **T1.2** Builder: overlap placement is done in `TransitionLayout.pieces` / `CompositionBuilder.makeVideoComposition`. The opacity-ramp form is exposed by `CompositionBuilder.crossDissolveLayerInstructions(...)` (`setOpacityRamp` on two `AVMutableVideoCompositionLayerInstruction`s) with a regression test (`crossDissolveLayerRamps`) and is reserved for a future native-export fast-path. Production cross-dissolves still run through `EffectCompositor.crossDissolve` (additive `RGB·(1-p) + RGB·p` for opaque inputs); the two forms produce mathematically different pixels (`setOpacityRamp` is source-over, midpoint = `(2B + A)/3` with `α=0.75`; additive midpoint = `(A + B)/2` with `α=1`) so we ship only one to keep preview and export pixel-identical (R5.1 / T3.1).
- [x] **T1.3** Wipe via `EffectCompositor` transition blend over the overlap interval.
- [x] **T1.4** Duration clamping to available overlap; unit tests for time ranges.

## UI

- [x] **T2.1** Add-transition action (toolbar/menu/context) at a selected cut.
- [x] **T2.2** Selectable transition glyph at the cut + inspector (type, duration); delete restores the cut.

## Verification

- [x] **T3.1** Smoke test: cross-dissolve + wipe scrub correctly; export matches preview.
- [x] **T3.2** `xcodebuild` green; tests green with no count regression.
