# Tasks: Phase 38 — Look Packs and Animated Overlays

> Status: **Proposed**. Depends on `feature-colour-grading`, `feature-project-persistence`, the keyframe spec, the title raster path.

## Looks (38a)

- [ ] **T1.1** Implement `GrainEffect` `CIKernel` with deterministic seeding.
- [ ] **T1.2** Implement `HalationEffect` `CIKernel`.
- [ ] **T1.3** Implement `VignetteEffect` `CIKernel`.
- [ ] **T1.4** Wire all three into the effect chain ordering (grade → looks → transform).
- [ ] **T1.5** `LookPresetV1` JSON codable + version migration scaffolding.
- [ ] **T1.6** Author ≥10 built-in look presets; bundle under `Resources/LookPresets/`.
- [ ] **T1.7** Import / export `.lclook` files; reference LUTs travel under `assets/luts/`.

## Overlays (38b)

- [ ] **T2.1** Animated image source: `ImageIO`-backed frame iterator with sliding-window decode.
- [ ] **T2.2** Lottie source: `lottie-ios` SPM, version-pinned; off-screen render → `CIImage` per frame; cache per `(file, time)`.
- [ ] **T2.3** Alpha-video source: `AVURLAsset` with alpha; compositor layer instruction honours alpha.
- [ ] **T2.4** Common `OverlayClip` model with start / duration / transform / opacity; integrates with the timeline as a new clip kind.
- [ ] **T2.5** Loop / freeze / hide-on-end controls on the overlay clip.

## Verification

- [ ] **T3.1** Snapshot tests for each built-in look preset.
- [ ] **T3.2** Lottie determinism test.
- [ ] **T3.3** Smoke: project with all three overlay kinds → scrub → export.
- [ ] **T3.4** Bundle round-trip: presets + LUTs + overlay sources + Lottie files persist under `assets/`.
- [ ] **T3.5** `xcodebuild` (Debug, macOS) green; no test count regression.
