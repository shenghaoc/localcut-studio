# Design: Phase 37 — Optical-Flow Frame Interpolation

> Status: **Proposed**. Target tag: **v0.2.5**. Blocked on macOS 27 leaving beta.

## Goal

Synthesise plausible in-between frames on-device for three uses: (a) smooth slow motion paired with Phase 35 speed ramps (a `synthesize` mode beside `duplicate` / `blend`); (b) fps upconversion at export (24 → 60); (c) optional motion-blur synthesis from the flow field. Honest about cost: time estimate before every run; render-cache-backed; export-only below the high tier; bounded-segment preview on high tier.

The browser-editor selects **Practical-RIFE 4.25 lite (MIT)** as the first conversion candidate, exposed via ORT-WebGPU with the renderer's `GPUDevice` shared with ORT. The native port targets a Core ML port of RIFE running on the Neural Engine + Metal compositor.

## Prerequisites

- Core ML port of RIFE-class interpolator. **No permissive Core ML conversion is bundled today**; the shipped manifest is a `template` and the feature stays hidden until a real model lands.
- Phase 35 speed ramps (depends on `synthesize` segment-mode being available).
- Phase 33 shot boundary detector (interpolation refuses to synthesise across cuts).
- Render cache (not yet specced) — invalidate cached frames on mode / factor / fps change.
- Capability tiers (not yet specced) — gates preview vs export-only behaviour.

## Approach

1. **Engine.** A Core ML model with two input tensors (`F0`, `F1`) + a scalar `tau` ∈ (0, 1) returning the interpolated frame. RIFE 4.25 lite has the right shape; we'd port the published ONNX through `coremltools`. License: MIT.
2. **Pipeline.** Zero-copy through the shared Metal device:
   ```
   CMSampleBuffer F0,F1 → IOSurface CVPixelBuffer → MTLTexture (input tensor via MPSGraph)
                                                                       ↓
                                                                  MLModel.predict
                                                                       ↓
                                                  MTLTexture output → CVPixelBuffer → compositor
   ```
3. **Tiling.** Probe-driven tile plan for ≥ 1080p inputs to bound VRAM; halo sized to the model's `maxDisplacement`; seam-free stitch; refuse (with a clear message) when the budget cannot even fit a minimum tile.
4. **Time-estimate.** Pre-run estimate from `frames × tilesPerFrame × calibratedMsPerTile` keyed by chip family + memory; surface in the diagnostics panel and the export dialog; aim for ±30 % of actual on fixtures.
5. **Capacity gating.** `Availability`: `preview-and-export` on high-tier Apple Silicon; `export-only` on mid-tier; `unavailable` on low-tier or without a usable model. The capability probe drives this.
6. **Cap factor.** ≤ 4× per frame pair in v1 (covers 24 → 60 and 0.25× slow-mo).
7. **Render cache.** `RenderCacheKey.interpolationHash` over `{mode, factorCap, targetFps, rampHash, modelId, computeUnits, tilingProfile, motionBlur}`; changes invalidate affected ranges; preview / export and proxy / original modes stay separated.
8. **Shot guard.** Calls Phase 33's shot detector; a boundary between `F0` and `F1` → refuse (hold or cut) and record the refusal; no model run.
9. **Failure mode.** A `template`, absent, or invalid manifest surfaces as "No compatible interpolation model configured" — same as upstream.

## Trade-offs

- Core ML over ONNX/ORT: native Core ML integrates with the Neural Engine without the WebGPU device-sharing dance; the cost is converting the model from ONNX → Core ML.
- Apple ships `VNGenerateOpticalFlowRequest` (Vision) which produces a 2-channel flow field — we evaluated using it for motion-blur synthesis but it is **not** a frame-interpolator. We'd still need RIFE for the interpolation itself; the flow field can drive the motion-blur option.
- No software / CPU fallback for the full-frame model: hosts without a sustainable Neural Engine see "unavailable".

## Risks

- Until a permissively-licensed RIFE Core ML model is vendored + verified, this phase ships hidden. The roadmap entry must call this out.
- Tiling at 4K with very fast motion can cause subtle seam artefacts; the halo size is a tunable trade-off documented in design.
- Calibration of the estimate per chip family requires fixture profiling time.

## Non-goals

- Realtime interpolation on all tiers.
- Video super-resolution.
- Interpolation across shot boundaries.
- Factors above 4× per pair in v1.
- Bitwise reproducibility (FP16 + Neural Engine nondeterminism accepted; cache is key-based).
