# Design: Phase 38 — Look Packs and Animated Overlays

> Status: **Proposed**. Target tag: **v0.1.6**. May split into 38a (looks) and 38b (overlays) if task count grows past ~25.

## Goal

(a) Film-emulation effect nodes (grain, halation, vignette) layered on the existing colour pipeline, plus a versioned JSON "look preset" format composing these with LUT references. (b) Animated overlays: animated image formats (animated WebP/AVIF/PNG/GIF) via `ImageIO`, Lottie via `lottie-ios`, and alpha-channel videos through the existing compositor.

## Prerequisites

- `feature-colour-grading`'s effect chain and LUT support.
- `feature-project-persistence` for bundle assets (LUTs and overlay sources ride in `assets/`).
- Title raster path (shared with Phase 30) for the rounded-corner / shadow framing of overlays.

## Approach

### A — Looks

1. **Grain node.** Resolution-independent hash noise in a `CIKernel`. Parameters: amount (0…1), size (in source pixels), monochrome toggle. Determinism keyed on a per-clip seed.
2. **Halation node.** Bright-red bleed: extract a luminance-thresholded mask, gaussian-blur the red channel of that mask, add back at user strength. CIKernel pipeline.
3. **Vignette node.** Radial darkening with adjustable inner / outer radius and softness. `CIVignette` is too rigid; use a CIKernel for the exact look.
4. **Look preset format.** `LookPresetV1` JSON composes an ordered list of `(effectName, params)` plus a reference to a `.cube` LUT. LUTs travel in the project bundle's `assets/luts/`; the preset stores a relative path. Built-in presets ship under `Resources/LookPresets/`.

### B — Overlays

1. **Animated images.** `ImageIO` decodes animated PNG / GIF / WebP / AVIF into a frame array with per-frame durations. We do not buffer the entire animation in RAM for long sources — instead we keep a sliding window keyed on the request time, decoded on demand by the worker.
2. **Lottie.** `lottie-ios` (Airbnb / community-maintained, satisfies AGENTS.md library criteria) renders into a `CALayer` driven off-screen by a Metal layer renderer that we sample into a `CIImage` per frame. Alternative considered: a WASM `rlottie` build — rejected because we have a native option that integrates with `CADisplayLink`-class timing.
3. **Alpha videos.** Standard `AVURLAsset` import; the compositor honours alpha by sampling RGBA and multiplying the layer instruction's opacity. We require the source to be a codec that AVFoundation can decode with alpha (ProRes 4444 + HEVC with alpha).

### Compositor integration

- Both looks and overlays are `Effect` / source layers in the existing `EffectCompositor`. Looks apply **after** the clip's colour-grading parameters but **before** clip transforms — documented ordering. Overlay layers composite above clip layers with their own transform / opacity.

## Trade-offs

- `lottie-ios` is a third-party dep; we justify it via AGENTS.md criteria (active development, organisational backing). Alternatives (rlottie via WASM) require more glue and lose timing fidelity.
- Animated AVIF decoding via `ImageIO` requires macOS 13+ and we're on 26 — fine.
- A look preset that references a missing LUT degrades to "neutral colour cube + warning" rather than failing the project load.

## Risks

- Lottie animations using effects (gaussian blur, drop shadow) that `lottie-ios` does not yet implement; the importer logs unsupported features and the user sees a warning.
- Per-frame on-demand decode of long animated images can stall if the disk is slow; prefetch one window ahead.

## Non-goals

- Asset marketplace / hosted catalogue.
- After Effects expression evaluation.
- Audio-reactive effects.
