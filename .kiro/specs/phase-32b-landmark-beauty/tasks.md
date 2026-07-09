# Tasks: Phase 32b — Landmark-Driven Beauty

> Status: **In progress on `next` branch**. Depends on Phase 32a, keyframes, `feature-colour-grading`. Targets macOS 27.

## Engine

- [ ] **T1.1** `actor LandmarkDetector` wrapping `VNDetectFaceLandmarksRequest`; primary-face picker.
- [ ] **T1.2** Detection-cadence orchestrator with interpolation between inference frames.
- [ ] **T1.3** One-Euro filter on each landmark point.
- [ ] **T1.4** Mesh-warp Metal compute pass — barycentric interpolation across triangles.
- [ ] **T1.5** Slider parameter → vertex-displacement mapping.

## Phase 32a integration

- [ ] **T2.1** Face-polygon mask from landmark contour.
- [ ] **T2.2** Multiply with Phase 32a chroma mask.
- [ ] **T2.3** Fallback to chroma-only when detection fails.

## UI

- [ ] **T3.1** Inspector "Beauty" sub-section: jaw / eye / nose / mouth sliders + strength cap.
- [ ] **T3.2** Keyframable parameters via the shared keyframe UI.

## Privacy

- [ ] **T4.1** Codable model excludes landmarks; only slider state persists.
- [ ] **T4.2** Diagnostics filter excludes face-derived data.

## Verification

- [ ] **T5.1** Identity test at strength 0.
- [ ] **T5.2** Smoothed landmark variance test on a fixture.
- [ ] **T5.3** Bundle round-trip preserves slider state only.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
