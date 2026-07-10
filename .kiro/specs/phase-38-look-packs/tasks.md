# Tasks: Phase 38 — Look Packs and Animated Overlays

> Status: **Implemented**. Depends on `feature-colour-grading`, `feature-project-persistence`, the keyframe spec, the title raster path.

## Looks (38a)

- [x] **T1.1** Implement `GrainEffect` Core Image pass with deterministic seeding and project-frame-rate cadence.
- [x] **T1.2** Implement `HalationEffect` Core Image pass.
- [x] **T1.3** Implement `VignetteEffect` Core Image pass.
- [x] **T1.4** Wire all three into the effect chain ordering (grade → looks → transform).
- [x] **T1.5** `LookPresetV1` JSON codable + version migration scaffolding.
- [x] **T1.6** Author ≥10 built-in look presets; bundle source JSON under `Resources/LookPresets/`.
- [x] **T1.7** Import / export `.lclook` files; referenced LUT sidecars travel under `assets/luts/`.
- [x] **T1.8** Source-local look strength keyframes, including retimed clips.
- [x] **T1.9** Negative vignette amount renders edge lift; clamping preserves Bezier keyframe handles.
- [x] **T1.10** Clamp decoded look-effect models, export LUT-only presets, and validate imported preset LUT sidecar paths.

## Overlays (38b)

- [x] **T2.1** Animated image source: `ImageIO`-backed frame iterator with sliding-window decode.
- [x] **T2.2** Lottie source: `lottie-ios` SPM, version-pinned; off-screen render → cached `CIImage` frames.
- [x] **T2.3** Alpha-video source: `AVURLAsset` with alpha; compositor layer instruction honours alpha.
- [x] **T2.4** Common `OverlayClip` model with start / duration / transform / opacity; integrates with the timeline as a new clip kind.
- [x] **T2.5** Loop / freeze / hide-on-end controls on the overlay clip.
- [x] **T2.6** Overlay-only, visual-gap, and tail intervals extend the video composition with filler frames.
- [x] **T2.7** Overlay transform honours source-natural scale and rotates around source centre.
- [x] **T2.8** Overlay source resolution validates bundle-relative paths and clears stale session selection/state.
- [x] **T2.9** Scope overlay source registries per preview/export session and release them with their owning render.
- [x] **T2.10** Use bounded on-demand alpha-video frame decode instead of a full-frame RAM cache.
- [x] **T2.11** Support APNG/WebP delay metadata and `.lottie` package loading without main-actor file/decompression work.
- [x] **T2.12** Expose overlay timing/position controls in the inspector and filter imports by selected source type.
- [x] **T2.13** Preserve bundled overlay sources when saving bundle-backed projects as single-file `.lcstudio` documents.
- [x] **T2.14** Persist and evaluate overlay position, scale, rotation, and
  opacity keyframes in preview/export, with inspector add/update/remove/clear
  controls and legacy static-value decoding.

## Verification

- [x] **T3.1** Snapshot tests for each built-in look preset.
- [x] **T3.2** Lottie determinism test.
- [x] **T3.3** Smoke: project with all three overlay kinds → export.
- [x] **T3.4** Bundle/resource round-trip: preset resources, LUT sidecars, overlay sources, and Lottie files persist under `assets/` where applicable.
- [x] **T3.5** Regression tests: source-local look keyframes, output-cadence grain, negative vignette, overlay transform, overlay-only/gap duration, path validation, overlay selection reset, import filtering, LUT-only exportability, decoded clamping, and single-file bundled-overlay preservation.
- [x] **T3.6** `xcodebuild` (Debug, macOS) green; no test count regression.
- [x] **T3.7** Regression tests cover overlay-keyframe interpolation, document
  round-trip, undo, removal, and preview/export render-item evaluation.
