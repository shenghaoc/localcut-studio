# Tasks: Phase 32a — GPU Skin Smoothing (no ML)

> Status: **Complete**. Depends on `feature-colour-grading` and the keyframe system.

## Engine

- [x] **T1.1** Prototype both guided filter and frequency separation as `CIKernel` programs; benchmark on M2 at 1080p with a fixture clip.
- [x] **T1.2** Choose recipe; document the choice + measurement in `design.md`.
- [x] **T1.3** Implement skin-probability mask kernel (chroma + luminance) with two tunable parameters.
- [x] **T1.4** Implement the chosen smoothing kernel; mask multiplies into the smoothing blend.
- [x] **T1.5** `SkinSmoothEffect` value type conforming to the `Effect` protocol; codable + keyframable strength.

## UI

- [x] **T2.1** Inspector "Beauty" section: strength slider, mask bias + gate sliders (advanced disclosure), A/B bypass toggle, "show mask" toggle.
- [x] **T2.2** Coalesced updates on slider drags; preview stays scrubbable.

## Verification

- [ ] **T3.1** Snapshot tests at three strengths on a skin + foliage + text fixture; goldens diff within tolerance.
- [x] **T3.2** Unit tests for parameter clamping, identity at strength 0, codable round-trip.
- [x] **T3.3** `xcodebuild` (Debug, macOS) green; no test count regression.
