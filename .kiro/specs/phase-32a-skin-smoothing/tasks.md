# Tasks: Phase 32a — GPU Skin Smoothing (no ML)

> Status: **Implemented**. Depends on `feature-colour-grading` and the keyframe system.

## Engine

- [x] **T1.1** Prototype smoothing approach; chose Gaussian blur proxy with mask blend (guided filter deferred).
- [x] **T1.2** Document choice in `design.md` — Gaussian blur proxy, not true guided filter.
- [x] **T1.3** Implement skin-probability mask kernel (chroma + luminance) with two tunable parameters.
- [x] **T1.4** Implement smoothing kernel (Gaussian blur + mask blend); `clampedToExtent()` to prevent edge bleeding and source-height radius scaling keeps the strength comparable across 1080p and 4K footage.
- [x] **T1.5** `SkinSmoothEffect` value type conforming to the `Effect` protocol; codable + keyframable strength in the model/compositor, with inspector controls for authoring strength keyframes.

## UI

- [x] **T2.1** Inspector "Beauty" section: strength slider, mask bias + gate sliders (advanced disclosure), A/B bypass toggle, "show mask" toggle.
- [x] **T2.2** Coalesced updates on slider drags; preview stays scrubbable. Accessibility labels on all controls.

## Verification

- [x] **T3.1** Snapshot tests at three strengths on a skin + foliage + graphics fixture; the skin band's high-frequency energy drops monotonically with strength while the foliage and graphics bands stay within tolerance (software-renderer "golden-less" form — deterministic on headless CI, no committed PNGs).
- [x] **T3.2** Unit tests for parameter clamping, identity at strength 0, codable round-trip.
- [x] **T3.3** Unit test for the 1080p reference blur-radius mapping and 4K/half-height scaling.
- [x] **T3.4** `xcodebuild` (Debug, macOS) green; no test count regression.
