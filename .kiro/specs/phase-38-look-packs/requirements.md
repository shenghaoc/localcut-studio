# Requirements: Phase 38 — Look Packs and Animated Overlays

## R1 — Looks

- **R1.1** `GrainEffect`, `HalationEffect`, `VignetteEffect` integrate into the per-clip effect chain.
- **R1.2** All three effects keyframable on their primary strength parameter.
- **R1.3** Grain is deterministic given a fixed per-clip seed; identical inputs yield identical pixels.

## R2 — Look presets

- **R2.1** `LookPresetV1` JSON file format with versioning; built-in presets ship in the app bundle.
- **R2.2** User presets import / export via `.fileImporter` / `NSSavePanel`; exported referenced LUT sidecars travel under `assets/luts/`.
- **R2.3** Looks compose with the existing per-clip colour-grading; ordering documented (grade → looks → transform).
- **R2.4** A missing referenced LUT loads with a neutral identity cube and a user-visible warning.

## R3 — Animated image overlays

- **R3.1** Decode animated PNG / GIF / WebP / AVIF via `ImageIO`; sliding-window decode on demand, no full-source RAM buffer.
- **R3.2** Frame-accurate timeline mapping: the overlay's frame at output time `t` matches the source's frame at `t - overlayStart` mod loop, honouring per-frame durations.
- **R3.3** Loop / freeze on end / hide on end controls.

## R4 — Lottie overlays

- **R4.1** `lottie-ios` (SPM, version-pinned) renders `.lottie` / `.json` into a layer sampled into the compositor.
- **R4.2** Frame-accurate timeline mapping that survives speed ramps (Phase 35).
- **R4.3** Unsupported Lottie features surface a warning at import time and at load time; do not silently render incorrectly.

## R5 — Alpha-channel video overlays

- **R5.1** ProRes 4444 and HEVC-with-alpha imports preserve alpha through the compositor.
- **R5.2** Layer transform + opacity + the standard transition primitives still work on alpha overlays.

## R6 — Verification

- **R6.1** Snapshot tests for each built-in look preset on a fixture clip at a fixed time.
- **R6.2** Lottie playback determinism test: same `.lottie` rendered twice at sampled times produces identical pixels.
- **R6.3** Smoke: import animated overlay + Lottie sticker + alpha video → scrub → export → all three composite correctly.
- **R6.4** Bundle save / load preserves overlay sources and Lottie files under `assets/`; preset resources and exported LUT sidecars round-trip through the `LookPresetV1` format.
- **R6.5** `xcodebuild` green; no test count regression.
