# Tasks: Phase 35 — Time Remapping

> Status: **Proposed**. Depends on keyframes + render cache + audio master bus + persistence.

## Model

- [ ] **T1.1** Add `speedCurve` to `Clip`; default identity at 1.0.
- [ ] **T1.2** Add preserve-pitch toggle and pitch-algorithm enum to `Clip`.
- [ ] **T1.3** Codable round-trip for the speed curve.

## Engine

- [ ] **T2.1** Speed-curve evaluator: continuous bezier → output-time → source-time mapping.
- [ ] **T2.2** Segment plan builder: keyframe pairs → ≥10 sub-segments each → `[(sourceRange, outputDuration)]`.
- [ ] **T2.3** Extend `CompositionBuilder` to apply the segment plan to the video track via `AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)`.
- [ ] **T2.4** Build `AVMutableAudioMix` with `audioTimePitchAlgorithm` mirroring the same segment plan.
- [ ] **T2.5** Snap segment boundaries to source-asset sample times; document the ±1 frame tolerance.

## UI

- [ ] **T3.1** Bezier curve editor in the inspector "Speed" section.
- [ ] **T3.2** Preserve-pitch toggle, algorithm picker, output-duration readout.
- [ ] **T3.3** Coalesced updates while dragging.

## Cache

- [ ] **T4.1** Invalidate render-cache entries for the affected output time range on ramp edit (no-op if pitch-only change).

## Verification

- [ ] **T5.1** Unit tests for evaluation, segment-plan, clamping, codable.
- [ ] **T5.2** Determinism test on a fixture project.
- [ ] **T5.3** Smoke: ramp → scrub → export → A/V parity at sampled positions.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
