# Design: Phase 38 — Look Packs and Animated Overlays

> Status: **Implemented**. Target tag: **v0.1.6**.

## Goal

(a) Film-emulation effect nodes (grain, halation, vignette) layered on the existing colour pipeline, plus a versioned JSON "look preset" format composing these with LUT references. (b) Animated overlays: animated image formats (animated WebP/AVIF/PNG/GIF) via `ImageIO`, Lottie via `lottie-ios`, and alpha-channel videos through the existing compositor.

## Prerequisites

- `feature-colour-grading`'s effect chain and LUT support.
- `feature-project-persistence` for bundle assets (LUTs and overlay sources ride in `assets/`).
- Title raster path (shared with Phase 30) for the rounded-corner / shadow framing of overlays.

## Approach

### A — Looks

1. **Grain node.** Resolution-independent Core Image noise pass. Parameters: amount (0…1), size (in source pixels), monochrome toggle. Determinism is keyed on a per-clip seed.
2. **Halation node.** Bright-red bleed: extract a thresholded bright-pass proxy, gaussian-blur it, warm the result, and add back at user strength.
3. **Vignette node.** Radial edge shading using Core Image's vignette filter with authored amount / radius / softness.
4. **Look preset format.** `LookPresetV1` JSON composes an ordered list of `(effectName, params)` plus an optional reference to a `.cube` LUT. Exported preset LUT sidecars travel under `assets/luts/`; the preset stores a relative path. Built-in preset source JSON ships under `Resources/LookPresets/` and is copied into the app bundle resources by Xcode.

### B — Overlays

1. **Animated images.** `ImageIO` decodes animated PNG / GIF / WebP / AVIF into a frame array with per-frame durations. We do not buffer the entire animation in RAM for long sources — instead we keep a sliding window keyed on the request time, decoded on demand by the worker.
2. **Lottie.** `lottie-ios` (originally Airbnb, now community-maintained as `airbnb/lottie-ios`) renders through an off-screen `LottieAnimationView`; frames are sampled into `CIImage`s before compositor use. Third-party dep justification (Phase 38 is the second of two such deps in the plan, alongside `GoogleWebRTC` in Phase 47): Apache-2.0 licence, organisational backing, active maintenance, no native Apple equivalent — `CAEmitterLayer` / `CAAnimation` / SwiftUI animation cover nothing of Lottie's After Effects JSON model, and writing one from scratch would dwarf the rest of the spec. Alternative considered: `rlottie` (Samsung) via a Swift wrapper — rejected because timing fidelity against `CADisplayLink` is worse and the WGSL-equivalent path would need a custom Metal renderer.
3. **Alpha videos.** Standard `AVURLAsset` import; the compositor honours alpha by sampling RGBA and multiplying the layer instruction's opacity. We require the source to be a codec that AVFoundation can decode with alpha (ProRes 4444 + HEVC with alpha).

### Compositor integration

- Both looks and overlays are `Effect` / source layers in the existing `EffectCompositor`. Looks apply **after** the clip's colour-grading parameters but **before** clip transforms — documented ordering. Overlay layers composite above clip layers with their own transform / opacity.

## Trade-offs

- `lottie-ios` is a third-party dep — see the in-place justification under "Lottie" above; this and `GoogleWebRTC` (Phase 47) are the only non-Apple media deps in the roadmap.
- Animated AVIF decoding via `ImageIO` requires macOS 13+ and we're on 26 — fine.
- A look preset that references a missing LUT degrades to "neutral colour cube + warning" rather than failing the project load.

## Risks

- Lottie animations using effects (gaussian blur, drop shadow) that `lottie-ios` does not yet implement; the importer logs unsupported features and the user sees a warning.
- Per-frame on-demand decode of long animated images can stall if the disk is slow; prefetch one window ahead.

## Non-goals

- Asset marketplace / hosted catalogue.
- After Effects expression evaluation.
- Audio-reactive effects.
