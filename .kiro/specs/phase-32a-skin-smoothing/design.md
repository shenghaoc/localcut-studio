# Design: Phase 32a — GPU Skin Smoothing (no ML)

> Status: **Implemented**. Target tag: **v0.1.2**.

## Goal

A pure-GPU beauty effect node in the per-clip effect chain: smoothing gated by a chroma-based skin-probability mask, with a single keyframable strength parameter. No face detection, no landmarks — those land later in Phase 32b once Core AI is available. Smoothing must leave non-skin regions (text, foliage, fabric) untouched at default strength.

## Prerequisites

- `feature-colour-grading`'s custom `AVVideoCompositing` and per-clip effect chain.
- The implemented keyframe system so `strength` can be evaluated over clip-local time. Phase 32a exposes the default strength in the inspector; timeline keyframe authoring UI is deferred.

## Approach

1. **Mask.** YCbCr skin-tone probability mask in a `CIKernel` (Metal-backed): the YCbCr / HSV ranges Apple's Vision uses for skin segmentation are well-documented; we replicate the chroma-only portion (no spatial prior). Output is a single-channel mask in `[0,1]`. Two tunable parameters (warmth bias, luminance gate) expose the obvious failure modes (very pale / very dark skin) without forcing the user into per-clip tuning.
2. **Smoothing.** **Gaussian blur proxy** (not a true guided filter). `CIGaussianBlur` is applied with `clampedToExtent()` to prevent edge bleeding, then blended back using the mask via a `CIColorKernel`. The authored strength maps to a 1080p reference radius (`strength == 1` → 10 source pixels) and scales linearly by source-frame height, so 4K footage receives a 20 px radius at the same strength instead of looking half as smooth. This approximates edge-preserving behavior at low strengths but does not preserve edges at high strengths. A true guided filter (using the image as its own guide) can be implemented later if needed. Both kernels are cached as `static let` to avoid per-frame compilation.
3. **Effect node.** `SkinSmoothEffect` conforms to the `Effect` protocol from `feature-colour-grading`. It owns one `strength: Keyframed<Float>` (0…1, default 0), one `maskWarmthBias`, one `maskLuminanceGate`, and a `bypass: Bool` for the inspector toggle.
4. **Inspector UI.** A "Beauty" section in the inspector with a default-strength slider, an A/B bypass toggle, a preview-only "show mask" toggle, advanced mask controls, and accessibility labels on all controls. The slider edits `strength.defaultValue`; keyframe curve editing is infrastructure-only in this PR.
5. **Performance.** Both the mask and smoothing kernels run on the Metal-backed `CIContext` shared with grading. Preview runs at the project render size or the proxy size if `feature-colour-grading` has wired proxy support; export runs full size.

## Trade-offs

- Chroma-only masks fail on prominent warm wood/clothing — we expose the gate parameters rather than hide them.
- Guided filter has a clearer edge-preserving promise; the shipped Gaussian blur proxy is simpler, faster to validate, and explicit about high-strength edge softening.
- Source-height radius scaling keeps the visual strength comparable across 1080p/4K footage while preserving source-pixel determinism in the shared preview/export compositor.
- A single global strength is honest; per-face strength belongs in 32b.
- Keyframe authoring UI would broaden the phase beyond the engine/compositor work, so this PR lands the model/evaluation path first.

## Risks

- Mask flicker on noisy footage — counter by smoothing the mask in the temporal domain (3-tap box) only if the prototype shows flicker; otherwise keep it spatially-only to avoid complicating the cache.
- Gaussian blur can soften high-contrast features at high strength. Keep defaults conservative and leave full guided-filter or frequency-separation work to a follow-up if fixture testing shows the proxy is not good enough.

## Non-goals

- Face detection, landmarks, geometry warps (瘦脸 / 大眼) — those are Phase 32b.
- Per-face masking or multi-subject strength.
- Automatic "beautify on" without explicit user action.
