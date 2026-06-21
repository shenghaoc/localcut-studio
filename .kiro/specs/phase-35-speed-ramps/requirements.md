# Requirements: Phase 35 — Time Remapping

## R1 — Speed model

- **R1.1** Per-clip `speedCurve: [Keyframe<Float>]` with values clamped to `[0.25, 4.0]`; defaults to a single keyframe of 1.0.
- **R1.2** A "preserve pitch" toggle (default true) and a `pitchAlgorithm: enum { timeDomain, spectral }` (default `.timeDomain`).
- **R1.3** Bezier handles on each keyframe; eased segments evaluate continuously.

## R2 — Composition

- **R2.1** Video segments insert with `AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)` per keyframe pair; eased curves approximate via ≥10 sub-segments per pair.
- **R2.2** Audio mirrors the same segment plan on the audio track with `AVMutableAudioMix` applying the chosen `audioTimePitchAlgorithm`.
- **R2.3** A / V sync at every keyframe boundary stays within one frame at the project's fps.

## R3 — UI

- **R3.1** Inspector "Speed" section with the bezier curve editor, preserve-pitch toggle, algorithm picker, read-only output duration.
- **R3.2** Drag handles snap with Shift held; right-click clears to default; coalesced updates keep preview interactive.

## R4 — Cache invalidation

- **R4.1** Editing the speed curve invalidates render-cache entries for the clip's affected output time range only (depends on render cache spec).
- **R4.2** Toggling preserve-pitch or changing the algorithm does NOT invalidate the video cache (audio-only change).

## R5 — Export

- **R5.1** `AVAssetExportSession` consumes the same composition + audio mix as preview; pixel + sample parity at sampled positions.
- **R5.2** Bounded memory on long clips: composition is built lazily; no full-track decode.

## R6 — Verification

- **R6.1** Unit tests for speed-curve evaluation, segment-plan construction, and clamping.
- **R6.2** Determinism: identical speed curves yield identical segment plans.
- **R6.3** Smoke: ramp a clip → preview scrub → export → preview / export pixel + audio sample match at sampled times.
- **R6.4** `xcodebuild` green; no test count regression.
