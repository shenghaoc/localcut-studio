# Design: Phase 37 — Frame Interpolation (VTFrameProcessor)

> Status: **Proposed**. Target tag: **v0.2.5**. Blocked on macOS 27 leaving beta so the ML tier shares one OS baseline; the underlying API is available from macOS 15.4 Sequoia onward.

## Goal

Synthesise plausible in-between frames on-device for three uses: (a) smooth slow motion paired with Phase 35 speed ramps (a `synthesize` mode beside `duplicate` / `blend`); (b) fps upconversion at export (24 → 60); (c) optional motion-blur synthesis from the flow field. Honest about cost: time estimate before every run; render-cache-backed; export-only below the high tier; bounded-segment preview on high tier.

The browser-editor selects **Practical-RIFE 4.25 lite (MIT)** as an ONNX model on ORT-WebGPU because the web platform has no native frame-interpolation API. The native port does NOT need to vendor a model: **Apple ships frame interpolation as a first-party VideoToolbox API (`VTFrameProcessor`) running on the Neural Engine** — equivalent in role to RIFE, with no licence / provenance / manifest concerns and no model download.

## Prerequisites

- Phase 35 speed ramps (depends on `synthesize` segment-mode being available).
- Phase 33 shot boundary detector (interpolation refuses to synthesise across cuts).
- Render cache (not yet specced) — invalidate cached frames on mode / factor / fps change.
- Capability tiers (not yet specced) — gates preview vs export-only behaviour.

## Approach

1. **Engine — `VTFrameProcessor`.** VideoToolbox's `VTFrameProcessor` exposes per-task configuration types we can pick from:
   - `VTLowLatencyFrameInterpolationConfiguration` — pair-wise mid-frame synthesis at sub-multiples; the direct Phase 35 `synthesize` ramp path.
   - `VTFrameRateConversionConfiguration` — full clip / source frame-rate conversion with built-in interpolation; the direct export-time 24→60 path.
   - `VTOpticalFlowConfiguration` — 2-channel flow field; drives the optional motion-blur synthesis.
   - `VTMotionBlurConfiguration` — flow-driven motion blur as a single processor call (we keep flow + custom blur in the design as an alternative for fine control).
   Each is constructed with input pixel-buffer attributes + frame supports; `VTFrameProcessor.process(…)` returns the synthesised buffer. All run on the Neural Engine on Apple Silicon.
2. **Pipeline (zero-copy).**
   ```
   CMSampleBuffer F0,F1 → IOSurface-backed CVPixelBuffer → VTFrameProcessor.process
                                                                       ↓
                                                  CVPixelBuffer → compositor
   ```
   No CPU pixel round-trip. `VTFrameProcessor` accepts and returns `CVPixelBuffer`s tied to the same `IOSurface`-backed pool the compositor uses.
3. **No model download, no manifest.** `VTFrameProcessor` ships with the OS; we feature-detect its presence (`if #available(macOS 15.4, *)`) and pick configurations by capability. There is no `template = hidden` flag; the feature is available the moment the OS version + chip meet the floor.
4. **Tiling.** `VTFrameProcessor` accepts arbitrary input sizes; under the hood it handles tiling for memory. We pass full-resolution buffers up to 4K; on inputs where the processor reports memory pressure we fall back to a manual two-tile plan with a halo sized to the configuration's documented displacement.
5. **Time-estimate.** Pre-run estimate from `frames × calibratedMsPerFrame` keyed by chip family + resolution; surface in the diagnostics panel and the export dialog; aim for ±30 % of actual on fixtures.
6. **Capacity gating.** `Availability`: `preview-and-export` on high-tier Apple Silicon (M3 Pro / Max / Ultra and newer with the Neural Engine + memory headroom for sustained 1080p); `export-only` on baseline Apple Silicon; `unavailable` on Intel Macs (no `VTFrameProcessor`) and on Apple Silicon hosts running below the minimum OS.
7. **Cap factor.** ≤ 4× per frame pair in v1 (covers 24 → 60 and 0.25× slow-mo). The `VTLowLatencyFrameInterpolation` path supports configurable sub-multiples; we drive recursion for non-midpoint instants up to the same cap.
8. **Render cache.** `RenderCacheKey.interpolationHash` over `{mode, factorCap, targetFps, rampHash, processorConfig, osVersion, motionBlur}`; changes invalidate affected ranges; preview / export and proxy / original modes stay separated. `osVersion` is in the hash so cached frames from a different OS interpolation revision don't get reused.
9. **Shot guard.** Calls Phase 33's shot detector; a boundary between `F0` and `F1` → refuse (hold or cut) and record the refusal; no `VTFrameProcessor` call.

## Trade-offs

- `VTFrameProcessor` over a vendored Core AI RIFE: no licence + provenance + Core AI conversion work; runs on the Neural Engine; ships with the OS; gets Apple's algorithmic improvements free with OS updates. The cost is: less control over the exact algorithm (we accept Apple's choices) and harder bit-exact reproducibility across OS versions (already a v1 non-goal).
- For motion-blur synthesis we have a choice: `VTMotionBlurConfiguration` directly (one call) vs. `VTOpticalFlowConfiguration` + a custom Metal blur (more control over shutter angle / direction). We default to the direct configuration; the custom path is the follow-up if creator feedback wants finer control.
- Realtime preview at proxy resolution is possible on high-tier hardware; we still surface the time estimate up-front because consistent behaviour matters more than hiding the cost.

## Risks

- `VTFrameProcessor` quality can vary across OS revisions; we keep `osVersion` in the cache key.
- Intel Macs have no `VTFrameProcessor` — the feature is correctly reported `unavailable` rather than a CPU-software fallback (which would be misleading).
- Per-clip determinism across Apple Silicon revisions is not guaranteed — same as accepted for any Neural Engine workload.

## Non-goals

- Realtime interpolation on all tiers.
- Video super-resolution (`VTSuperResolutionConfiguration` is available but out of scope here — could be a separate spec).
- Interpolation across shot boundaries.
- Factors above 4× per pair in v1.
- Bitwise reproducibility (FP16 + Neural Engine nondeterminism accepted; cache is key-based).
- Vendoring an external interpolation model (`VTFrameProcessor` removes the need).
