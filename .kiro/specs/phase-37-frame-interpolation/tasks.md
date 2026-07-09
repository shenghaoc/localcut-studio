# Tasks: Phase 37 — Frame Interpolation (VTFrameProcessor)

> Status: **Proposed**. Depends on Phase 35, Phase 33, render cache, capability tiers.
> **In progress on `next` branch** — targets macOS 27. The underlying
> `VTFrameProcessor` API is available from macOS 15.4 onward; this phase
> proceeds on `next` so every ML-tier feature shares one minimum-OS baseline
> when merged (see ROADMAP.md).

## Engine

- [ ] **T1.1** `InterpolationEngine` actor — owns a small pool of `VTFrameProcessor` instances, one per configuration kind. Each instance follows the lifecycle `init()` → `startSession(configuration:)` → repeated `process(with:parameters:)` → `endSession()`.
- [ ] **T1.2** Configuration types per use case: `VTLowLatencyFrameInterpolationConfiguration` for ramps; `VTFrameRateConversionConfiguration` for export upconversion; `VTOpticalFlowConfiguration` / `VTMotionBlurConfiguration` for motion blur. (All conform to `VTFrameProcessorConfiguration`. Configurations are NOT swapped on a live processor — a new processor + session is created per use case.)
- [ ] **T1.3** Two-step availability gate: `#available(macOS 15.4, *)` OS check + `try startSession(configuration:)` failure handler (catches Intel Macs that pass the OS check but throw at session start); both failure modes report `unavailable`.
- [ ] **T1.4** `synthesise(F0, F1, tau)` API surface backed by the chosen processor + configuration.

## Pipeline

- [ ] **T2.1** Zero-copy via `process(with: MTLCommandBuffer, parameters:)` — the Metal variant of `VTFrameProcessor.process`. Source / reference frames wrap as `VTFrameProcessorFrame`; output reads as `VTFrameProcessorFrame.ReadOnlyFrame`. Output frames feed the compositor without a CPU round-trip.
- [ ] **T2.2** Shared `CVPixelBufferPool` (`IOSurface`-backed) across source reader, `VTFrameProcessor`, and compositor.
- [ ] **T2.3** Per-clip lifetime: `init()` + `startSession(_:)` on first use; `endSession()` on seek, shot boundary, or clip switch; throwing `startSession` flips the engine to `unavailable`.

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
