# Requirements: Phase 32a — GPU Skin Smoothing (no ML)

> Status: **Implemented** with T3.1 snapshot/golden-image coverage deferred.

## R1 — Effect node

- **R1.1** `SkinSmoothEffect` integrates into the per-clip effect chain (depends on `feature-colour-grading`).
- **R1.2** Parameters: `strength` (0…1, keyframable in the model/compositor, inspector edits the default value for this phase), `maskWarmthBias` (−1…1, default 0), `maskLuminanceGate` (0…1, default 0.1), `bypass: Bool` (default false).
- **R1.3** Strength 0 must be a bit-exact identity (the effect is a no-op).

## R2 — Mask

- **R2.1** Chroma + luminance skin-probability mask implemented as a Metal-backed `CIKernel`; no per-pixel CPU work.
- **R2.2** A "show mask" overlay swaps the preview to the mask image without changing the render path otherwise.
- **R2.3** Non-skin regions (foliage, text, fabric) are targeted to receive minimal smoothing at default mask parameters. Golden-image verification remains deferred under T3.1.

## R3 — Smoothing

- **R3.1** Gaussian blur proxy with mask blend, justified in `design.md`; true guided filter / frequency separation is deferred.
- **R3.2** The blur input is clamped to avoid frame-edge bleeding, and the mask gates smoothing so the effect is not applied as a global blur. The current proxy can still soften masked edges at high strength.
- **R3.3** Deterministic output given identical inputs and parameters.

## R4 — Performance

- **R4.1** 1080p30 preview is realtime on an M2 with hardware acceleration on (no frame drops with skin smoothing as the only effect).
- **R4.2** 4K30 preview drops gracefully (frame drops, never a hang) and continues at the highest sustainable rate.

## R5 — Persistence

- **R5.1** Effect parameters and keyframes serialise through `ProjectDoc` and survive bundle round-trip.
- **R5.2** Reopening a project restores effect parameters, keyframes, and bypass state. The "show mask" toggle is preview-only session state and does not persist or export.

## R6 — Verification

- **R6.1** Deferred snapshot tests at strength = 0 (identity), 0.5 (subtle), 1.0 (max) on a fixture with skin + foliage + text regions.
- **R6.2** Unit tests for parameter clamping, default identity, and keyframe interpolation against the keyframe spec.
- **R6.3** `xcodebuild` (Debug, macOS) green; no test count regression.
