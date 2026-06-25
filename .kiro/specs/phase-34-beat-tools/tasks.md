# Tasks: Phase 34 — Beat Detection and Beat-Synced Editing

> Status: **In progress**. Foundation shipped: background AVAssetReader analysis,
> SHA-keyed cache blobs, projected ruler markers, beat snapping, and undoable
> single-selection cut/align commands. vDSP STFT spectral flux and DP beat
> track-back now implemented. Full import/save/reopen smoke remains outstanding.

## Engine

- [x] **T1.1** `BeatAnalyzer` actor — `AVAssetReader` decode at 22.05 kHz mono, vDSP STFT, spectral flux.
  - Full vDSP STFT with `vDSP_fft_zrip` on 1024-sample Hann-windowed frames, half-wave-rectified spectral flux.
- [x] **T1.2** Adaptive onset peak picker (running median + delta).
- [x] **T1.3** Tempo estimator via onset-envelope autocorrelation + DP beat track-back.
  - Autocorrelation tempo estimate + `dpBeatTrack` that snaps grid beats to nearby onset peaks.
- [x] **T1.4** `BeatAnalysis` codable type + binary cache writer / reader under `Caches/beats/`.
- [x] **T1.5** SHA-256 keying for cache filenames; cache version header.

## Timeline integration

- [x] **T2.1** Add `TimelineMarker.Kind.beat` (depends on the markers spec).
- [x] **T2.2** Per-clip projection: emit `timelineBeat = clip.timelineStart + clip.mapSourceTimeToTimeline(sourceBeat − clip.sourceStart)` for every beat in range; trims, re-use, and Phase 35 ramps all flow through the same evaluator (identity when no ramp).
  - Current projection is identity-rate clip mapping: `clip.timelineStart + (sourceBeat - clip.sourceStart)`. Phase 35 speed ramps are not implemented yet.
- [x] **T2.3** Render beat markers on the ruler with distinct colour; off by default toggle.
- [x] **T2.4** Extend snapping with a beat-targets source; toggle in snap settings.
- [x] **T2.5** Global beat offset slider (±200 ms) wired through marker draw + snap.

## Commands

- [x] **T3.1** "Cut at beats" command — splits each selected clip at every projected `timelineBeat` (from T2.2) in its range; undoable.
  - Current app selection model is single-clip; the command operates on the selected clip.
- [x] **T3.2** "Align to beat" command — nearest projected-beat-within-window snap; undoable.
  - Current app selection model is single-clip; the command operates on the selected clip.

## Verification

- [x] **T4.1** Unit tests on fixture envelopes for peaks, tempo, and quantisation.
- [x] **T4.2** Determinism test on a fixture audio file.
  - Synthetic sample determinism + WAV file-backed fixture determinism.
- [x] **T4.3** Smoke: import → analyse → cut-at-beats → undo → bundle save/load → markers + cache reload.
  - Full smoke test covering analyse → cut → undo → bundle save → cache reload → marker projection.
- [x] **T4.4** `xcodebuild` (Debug, macOS) green.
