# Tasks: Phase 34 — Beat Detection and Beat-Synced Editing

> Status: **Proposed**. Depends on timeline markers + `feature-project-persistence`.

## Engine

- [ ] **T1.1** `BeatAnalyzer` actor — `AVAssetReader` decode at 22.05 kHz mono, vDSP STFT, spectral flux.
- [ ] **T1.2** Adaptive onset peak picker (running median + delta).
- [ ] **T1.3** Tempo estimator via onset-envelope autocorrelation + DP beat track-back.
- [ ] **T1.4** `BeatAnalysis` codable type + binary cache writer / reader under `Caches/beats/`.
- [ ] **T1.5** SHA-256 keying for cache filenames; cache version header.

## Timeline integration

- [ ] **T2.1** Add `TimelineMarker.Kind.beat` (depends on the markers spec).
- [ ] **T2.2** Render beat markers on the ruler with distinct colour; off by default toggle.
- [ ] **T2.3** Extend snapping with a beat-targets source; toggle in snap settings.
- [ ] **T2.4** Global beat offset slider (±200 ms) wired through marker draw + snap.

## Commands

- [ ] **T3.1** "Cut at beats" command — clip split on every in-range beat; undoable.
- [ ] **T3.2** "Align to beat" command — nearest-beat-within-window snap; undoable.

## Verification

- [ ] **T4.1** Unit tests on fixture envelopes for peaks, tempo, and quantisation.
- [ ] **T4.2** Determinism test on a fixture audio file.
- [ ] **T4.3** Smoke: import → analyse → cut-at-beats → undo → bundle save/load → markers + cache reload.
- [ ] **T4.4** `xcodebuild` (Debug, macOS) green.
