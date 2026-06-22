# Tasks: Colour Grading

> Status: **Implemented**. Shipped in [#2](https://github.com/shenghaoc/localcut-studio/pull/2) (PR title: "Colour grading"). Code lives in `LocalCut Studio/EffectCompositor.swift`, `LocalCut Studio/CompositionBuilder.swift`, `LocalCut Studio/InspectorView.swift`, with `ColourGrade` + `Effect` types in `LocalCut Studio/Models.swift` and tests in `LocalCut StudioTests/EffectsTests.swift`.

## Model

- [x] **T1.1** Add `Effect` / `ColourGrade` types and `[Effect]` on `Clip` with neutral defaults + clamping.
- [x] **T1.2** Unit tests for clamping, defaults, and identity pass-through.

## Engine

- [x] **T2.1** Add a custom `AVVideoCompositionInstruction`/layer carrying each clip's effect chain.
- [x] **T2.2** Implement `EffectCompositor: AVVideoCompositing` with a shared Metal `CIContext`.
- [x] **T2.3** Map parameters → `CIFilter`s (colour controls, temperature/tint, exposure); LUT via `CIColorCubeWithColorSpace`.
- [x] **T2.4** Wire `customVideoCompositorClass` in `CompositionBuilder`; keep transform/opacity behaviour.

## UI

- [x] **T3.1** Inspector "Colour" section bound to the selected clip; coalesced updates.
- [x] **T3.2** LUT import (`.fileImporter` + bookmark) and per-clip reset.

## Verification

- [x] **T4.1** Smoke test: grade → scrub → export; preview matches export.
- [x] **T4.2** `xcodebuild` green; tests green with no count regression.
