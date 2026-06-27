# Tasks: Phase 38 — Look Packs and Animated Overlays

> Status: **Implemented**. Depends on `feature-colour-grading`, `feature-project-persistence`, the keyframe spec, the title raster path.

## Looks (38a)

- [x] **T1.1** Implement `GrainEffect` Core Image pass with deterministic seeding.
- [x] **T1.2** Implement `HalationEffect` Core Image pass.
- [x] **T1.3** Implement `VignetteEffect` Core Image pass.
- [x] **T1.4** Wire all three into the effect chain ordering (grade → looks → transform).
- [x] **T1.5** `LookPresetV1` JSON codable + version migration scaffolding.
- [x] **T1.6** Author ≥10 built-in look presets; bundle source JSON under `Resources/LookPresets/`.
- [x] **T1.7** Import / export `.lclook` files; referenced LUT sidecars travel under `assets/luts/`.

## Overlays (38b)

- [x] **T2.1** Animated image source: `ImageIO`-backed frame iterator with sliding-window decode.
- [x] **T2.2** Lottie source: `lottie-ios` SPM, version-pinned; off-screen render → cached `CIImage` frames.
- [x] **T2.3** Alpha-video source: `AVURLAsset` with alpha; compositor layer instruction honours alpha.
- [x] **T2.4** Common `OverlayClip` model with start / duration / transform / opacity; integrates with the timeline as a new clip kind.
- [x] **T2.5** Loop / freeze / hide-on-end controls on the overlay clip.

## Verification

- [x] **T3.1** Snapshot tests for each built-in look preset.
- [x] **T3.2** Lottie determinism test.
- [x] **T3.3** Smoke: project with all three overlay kinds → export.
- [x] **T3.4** Bundle/resource round-trip: preset resources, LUT sidecars, overlay sources, and Lottie files persist under `assets/` where applicable.
- [x] **T3.5** `xcodebuild` (Debug, macOS) green; no test count regression.
