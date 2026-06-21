# Tasks: Phase 37 — Optical-Flow Frame Interpolation

> Status: **Proposed**. Depends on Phase 35, Phase 33, render cache, capability tiers; blocked on macOS 27 leaving beta.

## Engine

- [ ] **T1.1** `InterpolationEngine` actor — owns `VTFrameProcessor` instances per configuration kind.
- [ ] **T1.2** Configuration picker: `VTLowLatencyFrameInterpolationConfiguration` for ramps; `VTFrameRateConversionConfiguration` for export upconversion; `VTOpticalFlowConfiguration` / `VTMotionBlurConfiguration` for motion blur.
- [ ] **T1.3** Feature-detect via availability gate; report `unavailable` on Intel + pre-macOS-15.4.
- [ ] **T1.4** `synthesise(F0, F1, tau)` API surface backed by the chosen configuration.

## Tiling + estimate

- [ ] **T3.1** `tiling.ts`-equivalent in Swift: VRAM budget → tile plan + halo.
- [ ] **T3.2** Estimate calculator keyed by chip family; per-tile ms calibration.

## Cache + shot guard

- [ ] **T4.1** Render-cache key extension with interpolation hash.
- [ ] **T4.2** Invalidate affected ranges on ramp / mode / factor / motion-blur change.
- [ ] **T4.3** Shot-guard wrapper calling Phase 33 detector.

## UI

- [ ] **T5.1** Inspector mode picker on Phase 35 ramps: `duplicate` / `blend` / `synthesize`.
- [ ] **T5.2** Export dialog fps-upconvert option + motion-blur toggle.
- [ ] **T5.3** Pre-run estimate display + cancel.

## Verification

- [ ] **T6.1** SSIM floor on panning fixture.
- [ ] **T6.2** VRAM bound at 1080p + 4K.
- [ ] **T6.3** Render-cache invalidation correctness.
- [ ] **T6.4** Estimate ±30 % on fixtures.
- [ ] **T6.5** `xcodebuild` (Debug, macOS) green.
