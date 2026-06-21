# Tasks: Phase 37 — Optical-Flow Frame Interpolation

> Status: **Proposed**. Depends on Phase 35, Phase 33, render cache, capability tiers; blocked on macOS 27 leaving beta. Hidden until a permissive Core ML RIFE-class model is vendored.

## Model + manifest

- [ ] **T1.1** Convert / vendor a permissive RIFE-class Core ML model; record provenance + licence.
- [ ] **T1.2** `InterpolationManifest.swift` — SHA-256 pinned, `template` flag rejected at load.
- [ ] **T1.3** Manifest validator + integrity check.

## Engine

- [ ] **T2.1** `InterpolationEngine` actor — loads the model, exposes `synthesise(F0, F1, tau)`.
- [ ] **T2.2** `IOSurface` `CVPixelBuffer` → `MTLTexture` preprocess.
- [ ] **T2.3** Core ML predict via `MLPredictionOptions(usesCPUOnly: false)`.
- [ ] **T2.4** Postprocess `MTLTexture` → compositor target.

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
