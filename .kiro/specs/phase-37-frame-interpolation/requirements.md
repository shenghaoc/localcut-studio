# Requirements: Phase 37 — Optical-Flow Frame Interpolation

## R1 — Engine

- **R1.1** `VTFrameProcessor` is the engine; no external model is vendored.
- **R1.2** Feature-detect via `if #available(macOS 15.4, *)`; the feature reports `unavailable` on older OS or on Intel Macs.
- **R1.3** Per-task configurations chosen by use: `VTLowLatencyFrameInterpolationConfiguration` for ramps, `VTFrameRateConversionConfiguration` for export upconversion, `VTOpticalFlowConfiguration` (or `VTMotionBlurConfiguration`) for motion blur.

## R2 — Pipeline

- **R2.1** Zero-copy: `IOSurface`-backed `CVPixelBuffer` → `VTFrameProcessor` → `CVPixelBuffer` → compositor; no CPU pixel round-trip.
- **R2.2** Frame interpolation uses the same `IOSurface` pool as the compositor.

## R3 — Tiling + VRAM

- **R3.1** Probe-driven tile plan for ≥ 1080p inputs.
- **R3.2** Halo sized to model's `maxDisplacement`; seam-free stitching.
- **R3.3** Refuse (with explicit message) when a minimum tile won't fit; never crash.

## R4 — Estimate

- **R4.1** Pre-run time estimate surfaced before any run; within ±30 % on fixture hardware profiles.
- **R4.2** Estimate states the chosen compute units (Neural Engine / GPU / CPU).

## R5 — Capability gating

- **R5.1** `preview-and-export` on high-tier Apple Silicon; `export-only` on mid-tier; `unavailable` otherwise.
- **R5.2** Probe failures fall back to "unavailable" with no silent CPU degrade.

## R6 — Cap factor

- **R6.1** ≤ 4× per frame pair in v1.

## R7 — Render cache

- **R7.1** Cache invalidation hash includes mode, factor cap, target fps, ramp hash, model id, compute units, tile profile, motion-blur toggle.
- **R7.2** Changing any of those invalidates affected output ranges only.
- **R7.3** Preview / export and proxy / original modes stay separated.

## R8 — Shot boundaries

- **R8.1** Shot guard refuses synthesis across cuts (calls Phase 33 detector).

## R9 — Verification

- **R9.1** Quality floor vs reference on panning fixtures (SSIM threshold).
- **R9.2** VRAM stays within the probed bound at 1080p and 4K via tiling.
- **R9.3** Render-cache invalidation correctness when mode / factor changes.
- **R9.4** Time estimate within ±30 % on fixtures.
- **R9.5** `xcodebuild` (Debug, macOS) green; no test count regression.
