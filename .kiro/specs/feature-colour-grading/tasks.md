# Tasks: Colour Grading

> Status: **Proposed**.

## Model

- [ ] **T1.1** Add `Effect` / `ColourGrade` types and `[Effect]` on `Clip` with neutral defaults + clamping.
- [ ] **T1.2** Unit tests for clamping, defaults, and identity pass-through.

## Engine

- [ ] **T2.1** Add a custom `AVVideoCompositionInstruction`/layer carrying each clip's effect chain.
- [ ] **T2.2** Implement `EffectCompositor: AVVideoCompositing` with a shared Metal `CIContext`.
- [ ] **T2.3** Map parameters → `CIFilter`s (colour controls, temperature/tint, exposure); LUT via `CIColorCubeWithColorSpace`.
- [ ] **T2.4** Wire `customVideoCompositorClass` in `CompositionBuilder`; keep transform/opacity behaviour.

## UI

- [ ] **T3.1** Inspector "Colour" section bound to the selected clip; coalesced updates.
- [ ] **T3.2** LUT import (`.fileImporter` + bookmark) and per-clip reset.

## Verification

- [ ] **T4.1** Smoke test: grade → scrub → export; preview matches export.
- [ ] **T4.2** `xcodebuild` green; tests green with no count regression.
