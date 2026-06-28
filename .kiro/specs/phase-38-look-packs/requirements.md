# Requirements: Phase 38 — Look Packs and Animated Overlays

## R1 — Looks

- **R1.1** `GrainEffect`, `HalationEffect`, `VignetteEffect` integrate into the per-clip effect chain.
- **R1.2** All three effects keyframable on their primary strength parameter.
- **R1.3** Grain is deterministic given a fixed per-clip seed and project frame rate; identical inputs yield identical pixels.
- **R1.4** Look strength keyframes are authored in clip source-local time and continue to target the same source frames under speed ramps.
- **R1.5** Positive vignette amounts darken edges; negative amounts produce an edge-lift look instead of silently no-oping.
- **R1.6** Decoded look-effect parameters are clamped on load so malformed project/preset JSON cannot persist out-of-range render values.

## R2 — Look presets

- **R2.1** `LookPresetV1` JSON file format with versioning; built-in presets ship in the app bundle.
- **R2.2** User presets import / export via `.fileImporter` / `NSSavePanel`; exported referenced LUT sidecars travel under `assets/luts/`.
- **R2.3** Looks compose with the existing per-clip colour-grading; ordering documented (grade → looks → transform).
- **R2.4** A missing referenced LUT loads with a neutral identity cube and a user-visible warning.
- **R2.5** LUT-only clips are exportable as look presets; imported preset LUT paths must validate as `assets/luts/*.cube` with no traversal.

## R3 — Animated image overlays

- **R3.1** Decode animated PNG / GIF / WebP / AVIF via `ImageIO`; sliding-window decode on demand, no full-source RAM buffer.
- **R3.2** Frame-accurate timeline mapping: the overlay's frame at output time `t` matches the source's frame at `t - overlayStart` mod loop, honouring per-frame durations.
- **R3.3** Loop / freeze on end / hide on end controls.
- **R3.4** Overlay transform uses source-natural pixel size: `scale == 1` preserves natural size, with rotation around the source centre.
- **R3.5** Overlay-only projects, overlay/caption gaps before or between video clips, and overlay tails beyond the last video clip extend the composition with filler video so preview/export render the full visual interval.
- **R3.6** Overlay source file import is filtered and validated by the chosen source type; selecting another editable target clears overlay selection.
- **R3.7** Overlay frame sources are scoped per preview/export render session so overlapping rebuilds and queued exports cannot race through a shared global source map.

## R4 — Lottie overlays

- **R4.1** `lottie-ios` (SPM, version-pinned) renders `.lottie` / `.json` into a layer sampled into the compositor.
- **R4.2** Frame-accurate timeline mapping that survives speed ramps (Phase 35).
- **R4.3** Unsupported Lottie features surface a warning at import time and at load time; do not silently render incorrectly.
- **R4.4** Lottie JSON reads, `.lottie` package decompression, and warning scans run off the main actor where AppKit is not required.

## R5 — Alpha-channel video overlays

- **R5.1** ProRes 4444 and HEVC-with-alpha imports preserve alpha through the compositor.
- **R5.2** Layer transform + opacity + the standard transition primitives still work on alpha overlays.
- **R5.3** Alpha-video overlays index sample timestamps up front and decode frames on demand with a bounded cache rather than buffering every frame.

## R6 — Verification

- **R6.1** Snapshot tests for each built-in look preset on a fixture clip at a fixed time.
- **R6.2** Lottie playback determinism test: same `.lottie` rendered twice at sampled times produces identical pixels.
- **R6.3** Smoke: import animated overlay + Lottie sticker + alpha video → scrub → export → all three composite correctly.
- **R6.4** Bundle save / load preserves overlay sources and Lottie files under `assets/`; preset resources and exported LUT sidecars round-trip through the `LookPresetV1` format.
- **R6.5** Bundle-relative overlay paths are validated before load, preview, queue reconstruction, or export.
- **R6.6** Single-file saves converted from bundles preserve bundled overlay sources via bookmarks before stripping bundle-relative paths.
- **R6.7** `xcodebuild` green; no test count regression.
