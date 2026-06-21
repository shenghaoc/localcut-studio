# Design: Phase 32a — GPU Skin Smoothing (no ML)

> Status: **Proposed**. Target tag: **v0.1.2**.

## Goal

A pure-GPU beauty effect node in the per-clip effect chain: smoothing gated by a chroma-based skin-probability mask, with a single keyframable strength parameter. No face detection, no landmarks — those land later in Phase 32b once Core AI is available. Smoothing must leave non-skin regions (text, foliage, fabric) untouched at default strength.

## Prerequisites

- `feature-colour-grading`'s custom `AVVideoCompositing` and per-clip effect chain.
- Keyframes (not yet specced) so `strength` animates over time.

## Approach

1. **Mask.** YCbCr skin-tone probability mask in a `CIKernel` (Metal-backed): the YCbCr / HSV ranges Apple's Vision uses for skin segmentation are well-documented; we replicate the chroma-only portion (no spatial prior). Output is a single-channel mask in `[0,1]`. Two tunable parameters (warmth bias, luminance gate) expose the obvious failure modes (very pale / very dark skin) without forcing the user into per-clip tuning.
2. **Smoothing.** Two implementations to pick from in `design.md` after a prototype shootout:
   - **Guided filter** (preserves edges via the input image as the guide; smooths only the low-frequency component on the masked region).
   - **Frequency separation** (low-pass + high-pass split; blend smoothed low-pass back with the original high-pass according to mask and strength).
   We default to guided filter unless a prototype shows it costs more than 4 ms/frame on M2 at 1080p; frequency separation is the fallback.
3. **Effect node.** `SkinSmoothEffect` conforms to the `Effect` protocol from `feature-colour-grading`. It owns one `strength: Keyframed<Float>` (0…1, default 0), one `maskWarmthBias`, one `maskLuminanceGate`, and an `aBBypass: Bool` for the inspector toggle.
4. **Inspector UI.** A "Beauty" section in the inspector with a strength slider, an A/B bypass toggle, and a "show mask" overlay button that swaps the preview to the mask image so the user can verify it lands on skin.
5. **Performance.** Both the mask and smoothing kernels run on the Metal-backed `CIContext` shared with grading. Preview runs at the project render size or the proxy size if `feature-colour-grading` has wired proxy support; export runs full size.

## Trade-offs

- Chroma-only masks fail on prominent warm wood/clothing — we expose the gate parameters rather than hide them.
- Guided filter has a clearer "edge-preserving" promise; frequency separation is the older industry-standard recipe.
- A single global strength is honest; per-face strength belongs in 32b.

## Risks

- Mask flicker on noisy footage — counter by smoothing the mask in the temporal domain (3-tap box) only if the prototype shows flicker; otherwise keep it spatially-only to avoid complicating the cache.
- Frequency separation can introduce halos near hair boundaries; the guided filter is preferable when feasible.

## Non-goals

- Face detection, landmarks, geometry warps (瘦脸 / 大眼) — those are Phase 32b.
- Per-face masking or multi-subject strength.
- Automatic "beautify on" without explicit user action.
