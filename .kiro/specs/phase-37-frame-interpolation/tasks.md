# Tasks: Phase 37 — Frame Interpolation (VTFrameProcessor)

> Status: **Proposed**. Depends on Phase 35, Phase 33, render cache, capability tiers.
> **Blocked on macOS 27 leaving beta** — the underlying `VTFrameProcessor` API
> is available from macOS 15.4 onward, but this phase is held so every ML-tier
> feature shares one minimum-OS baseline (see ROADMAP.md).

## Engine

- [ ] **T1.1** `InterpolationEngine` actor — owns `VTFrameProcessor` instances per configuration kind.
- [ ] **T1.2** Configuration picker: `VTLowLatencyFrameInterpolationConfiguration` for ramps; `VTFrameRateConversionConfiguration` for export upconversion; `VTOpticalFlowConfiguration` / `VTMotionBlurConfiguration` for motion blur.
- [ ] **T1.3** Two-step availability gate: `#available(macOS 15.4, *)` OS check + runtime session-start probe (catches Intel Macs that pass the OS check but lack a Neural Engine); both failure modes report `unavailable`.
- [ ] **T1.4** `synthesise(F0, F1, tau)` API surface backed by the chosen configuration.

## Pipeline

- [ ] **T2.1** Zero-copy `CMSampleBuffer` → `IOSurface`-backed `CVPixelBuffer` input into `VTFrameProcessor.process(…)`; output `CVPixelBuffer` consumed directly by the compositor (no Metal-texture round-trip needed; the processor handles GPU residency).
- [ ] **T2.2** Shared `CVPixelBufferPool` between the source reader, `VTFrameProcessor`, and the compositor to avoid allocations on the hot path.
- [ ] **T2.3** Per-clip lifetime: spin up + tear down a `VTFrameProcessor` instance per clip-session; reset on seek and shot boundary.

## Tiling + estimate

- [ ] **T3.1** Tile planner in Swift: probe-derived VRAM budget → tile plan + halo sized to the chosen configuration's documented displacement.
- [ ] **T3.2** Estimate calculator keyed by chip family + resolution; per-frame ms calibration.

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
