# Requirements: Phase 32b — Landmark-Driven Beauty

## R1 — Detection + landmarks

- **R1.1** `VNDetectFaceLandmarksRequest` (`VNFaceLandmarks2D.allPoints`) drives the warp.
- **R1.2** Detection cadence default every 3 frames at 30 fps; configurable.
- **R1.3** Between inference frames, landmarks linearly interpolate between cached endpoints.

## R2 — Smoothing

- **R2.1** One-Euro filter on each landmark point (`minCutoff = 1.0`, `beta = 0.007`).
- **R2.2** No visible landmark jitter on fixture footage (smoothed landmark variance below a documented bound).

## R3 — Primary face

- **R3.1** Single primary face: largest × proximity-to-centre score; deterministic tiebreak.
- **R3.2** Multi-face is not in v1; the UI states this plainly.

## R4 — Warp parameters

- **R4.1** Jaw slim, eye enlarge, nose width, mouth — each keyframable, each defaulting subtle.
- **R4.2** Strength 0 yields a bit-exact identity output.
- **R4.3** Slider effect attenuates as per-landmark confidence drops.

## R5 — Mask upgrade

- **R5.1** Phase 32a's chroma skin mask multiplies with a face-region polygon mask from the landmark contour.
- **R5.2** Phase 32a remains functional without landmarks (chroma-only) when detection fails.

## R6 — Privacy

- **R6.1** Raw landmarks, face coordinates, and inferred geometry are NEVER persisted to `ProjectDoc` or bundles.
- **R6.2** Diagnostics exclude face-derived data.

## R7 — Performance

- **R7.1** 1080p preview realtime on Apple Silicon (M2-class) at the chosen detection cadence.

## R8 — Verification

- **R8.1** Identity test: strength 0 → bit-exact identity.
- **R8.2** Smoothed landmark variance test on a fixture clip.
- **R8.3** Settings round-trip `ProjectDoc` and bundles; landmarks themselves do NOT round-trip.
- **R8.4** `xcodebuild` (Debug, macOS) green; no test count regression.
