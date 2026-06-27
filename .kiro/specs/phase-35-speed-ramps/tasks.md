# Tasks: Phase 35 — Time Remapping

> Status: **Implemented**. Source-domain Bezier speed model, composition
> retiming, pitch-preserving audio-mix wiring, inspector curve editing,
> source sample-time snapping, affected-range cache invalidation, persistence,
> and preview/export smoke coverage are implemented.

## Model

- [x] **T1.1** Add `speedCurve` to `Clip`; default identity at 1.0.
- [x] **T1.2** Add preserve-pitch toggle and pitch-algorithm enum to `Clip`.
- [x] **T1.3** Codable round-trip for the speed curve.

## Engine

- [x] **T2.1** Speed-curve evaluator: continuous bezier → output-time → source-time mapping.
- [x] **T2.2** Segment plan builder: keyframe pairs → ≥10 sub-segments each → `[(sourceRange, outputDuration)]`.
- [x] **T2.3** Extend `CompositionBuilder` to apply the segment plan to the video track via `AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)`, with each ramped clip on its own dedicated track.
- [x] **T2.4** Apply the SAME segment plan to the matching audio composition track via `AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)` — the audio track is retimed by the same scale segments as video, otherwise audio plays at original duration and drifts. Then build `AVMutableAudioMix` with `AVMutableAudioMixInputParameters(track:)` setting `audioTimePitchAlgorithm` per input parameter; the algorithm only governs pitch-preserving stretch quality on the already-retimed audio.
- [x] **T2.5** Snap segment boundaries to source-asset sample times; document the ±1 frame tolerance.

## UI

- [x] **T3.1** Bezier curve editor in the inspector "Speed" section.
- [x] **T3.2** Preserve-pitch toggle, algorithm picker, output-duration readout.
- [x] **T3.3** Coalesced updates while dragging.

## Cache

- [x] **T4.1** Invalidate render-cache entries for the affected output time range on ramp edit (no-op if pitch-only change).

## Verification

- [x] **T5.1** Unit tests for evaluation, segment-plan, clamping, codable.
- [x] **T5.2** Determinism test on a fixture project.
- [x] **T5.3** Smoke: ramp → scrub → export → A/V parity at sampled positions.
- [x] **T5.4** `xcodebuild` (Debug, macOS) green.
