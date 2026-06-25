# Tasks: Phase 34 — Beat Detection and Beat-Synced Editing

> Status: **Complete**. Target tag: **v0.1.3**. Offline beat analysis on a
> background actor, SHA-keyed `.beat` caches that ship in the project bundle,
> projected ruler markers, beat snapping, undoable cut/align commands, and a
> global offset — all reachable from the inspector and the Edit menu. The pure
> detection engine lives in `LocalCutCore`; only the AVFoundation decode stays in
> the app target. The CI bring-up defects (`bugfix-phase-34-beat-ci`) are folded
> in below.

## Engine

- [x] **T1.1** `BeatAnalyzer` actor — `AVAssetReader` decode at 22.05 kHz mono,
  feeding `BeatDetectionCore`'s vDSP STFT spectral flux.
  - Full vDSP STFT with `vDSP_fft_zrip` on 1024-sample Hann-windowed frames
    (50 % overlap), half-wave-rectified spectral flux.
- [x] **T1.2** Adaptive onset peak picker (running median + delta).
- [x] **T1.3** Tempo estimator via onset-envelope autocorrelation + DP beat
  track-back.
  - Autocorrelation tempo estimate (with sub-harmonic/octave correction, see
    **B3**) + `dpBeatTrack` that snaps grid beats to nearby onset peaks.
- [x] **T1.4** `BeatAnalysis` codable type + binary cache writer / reader under
  `Caches/beats/`.
- [x] **T1.5** SHA-256 keying for cache filenames; cache version header (v2).

## Timeline integration

- [x] **T2.1** Beat markers are a distinct **projected overlay**
  (`ProjectedBeatMarker { id, time }`), not a stored `TimelineMarker` kind.
  - Beat markers are derived from analysis and re-project per clip on every
    geometry change, so they are intentionally **not** persisted as authored
    `TimelineMarker`s (which carry `{ id, time, name, colour }` and *do* export).
    The original "add `TimelineMarker.Kind.beat`" framing was superseded by this
    projected-overlay design; the prerequisite markers spec is unchanged.
- [x] **T2.2** Per-clip projection: `timelineBeat = clip.timelineStart +
  (sourceBeat − clip.sourceStart) + offset` for every in-range beat; trims and
  re-use flow through the same evaluator.
  - Identity-rate mapping. Phase 35 speed ramps don't exist yet, so the identity
    map is the complete and correct behaviour for this phase; the projection is
    structured so the Phase 35 speed-curve evaluator drops in without touching
    callers.
- [x] **T2.3** Render beat markers on the ruler with a distinct colour; off by
  default toggle (`showBeatMarkers`, default `false`). Markers are view-only and
  do not export.
- [x] **T2.4** Extend snapping with a beat-targets source; toggle in snap
  settings (`snapToBeats`); reuses the existing snap radius.
- [x] **T2.5** Global beat offset slider (±200 ms) wired through marker draw +
  snap; takes effect live (see **T6**).

## Commands

- [x] **T3.1** "Cut at beats" command — splits the selected clip at every in-range
  beat from *that clip's own* analysis; undoable. Reachable from the inspector
  ("Cut") and the Edit menu ("Cut Selected Clip at Beats").
  - Current app selection model is single-clip; the command operates on the
    selected clip.
- [x] **T3.2** "Align to beat" command — nearest projected-beat-within-window
  snap; undoable. Reachable from the inspector ("Align") and the Edit menu.
  - Current app selection model is single-clip; the command operates on the
    selected clip.
- [x] **T3.3** A failed analysis (DRM, corrupt, no audio) surfaces in
  `statusMessage` and never blocks editing (R4.3).

## Engine boundary (honours `feature-localcutcore-package` / PR #37)

- [x] **T5.1** Pure detection logic — `BeatDetectionCore` (vDSP STFT, peak
  picking, autocorrelation tempo + octave correction, DP track-back, CMTime
  quantisation), the `BeatAnalysis` model, `ProjectedBeatMarker`, `BeatAnalysisError`,
  and the `BeatAnalysisCache` binary format — lives in
  `Packages/LocalCutCore/Sources/LocalCutCore/Beats/`. No SwiftUI, no AVFoundation.
- [x] **T5.2** Only the AVFoundation decode (`BeatAnalyzer.decodeMonoSamples`)
  stays in the app target (`LocalCut Studio/BeatTools.swift`), which feeds samples
  into `BeatDetectionCore`.

## Projected-beat cache correctness

- [x] **T6.1** The `projectedBeatTimes()` memo (`projectedBeatTimesRevision`) is
  invalidated whenever any input changes: `didSet` on `beatOffsetSeconds` and
  `beatAnalyses`, and a single `invalidateProjectedBeatTimesCache()` call in
  `scheduleRebuild()` — the chokepoint every clip-geometry edit (trim, move,
  split, delete, cut/align, undo, redo, persistence reload) already passes
  through. The memo survives playhead-only redraws (no geometry change), keeping
  the hot ruler-draw path cheap.
- [x] **T6.2** "Cut at beats" derives cuts from the selected clip's own analysis
  (not the global projected set), so an overlapping unrelated clip's beats can't
  bleed into the cut points and the command is independent of the memo.
- [x] **T6.3** Detached analysis / cache-load completions only adopt results for
  media still present in the current project (guards a document switch landing
  stale beats), on top of the existing task cancellation.

## Verification

- [x] **T4.1** Unit tests on fixture envelopes for peaks, tempo, and quantisation
  — in `LocalCutCore` (`swift test`).
- [x] **T4.2** Determinism: synthetic-sample determinism (`LocalCutCore`) +
  WAV-file-backed decode determinism (app target).
- [x] **T4.3** Reopen smoke: `reopenReloadsBeatCachesAndMarkers` writes a real
  WAV, analyses it, persists the `.beat` blob into a bundle, then a fresh
  `EditorModel` pointed at that bundle reloads it through the real
  `loadAvailableBeatCaches()` entry point and projects markers. Plus
  `fullSmokeTest` (analyse → cut → undo → bundle save → cache reload → projection).
- [x] **T4.4** Cache-invalidation regressions: offset change re-projects,
  analysis arrival re-projects after an empty seed, clip move re-projects after
  `scheduleRebuild`.
- [x] **T4.5** `swift test` (LocalCutCore) and `xcodebuild test` (Debug, macOS)
  green; no test-count regression.

## Defects fixed during bring-up (folded from `bugfix-phase-34-beat-ci`)

The hosted `Test (macOS 26 / Xcode)` parallel-worker run surfaced three defects
the local run missed; a fourth (stale caches) followed from the estimator change.
See the design note "Defects fixed during bring-up" for the full analysis.

- [x] **B1** `onsetEnvelope` calls `vDSP_fft_zrip` (real in-place FFT) instead of
  `vDSP_fft_zip`, matching the `halfN` packed split-complex buffer — fixes a heap
  overrun that crashed the whole xctest worker.
- [x] **B2** `dpBeatTrack` anchors its grid on `firstPeakTime` instead of the
  backward-projected phase, dropping a spurious leading beat in leading silence.
- [x] **B3** `estimateTempoBPM` adds a sub-harmonic (octave) correction: after the
  bare autocorrelation peak, if a lag near `bestLag/2` or `bestLag/3` retains ≥
  `octaveEnergyFraction` (0.5) of the peak's raw onset energy, step down to that
  faster fundamental. Deterministic `[lower, upper]` candidate order (no `Set`).
- [x] **B4** `BeatAnalysisCache.version` bumped 1 → 2 so v1 blobs holding the old
  half-tempo result are rejected and re-analysed after upgrade.
- [x] **V1–V6** CI green on the PR head; `deterministicFileAnalysis` within 5 BPM
  of 120; `dpBeatTrackSnapsToPeaks` lands beats on the four peaks; `tempoEstimate`
  unchanged at exactly 120; a genuine 60 BPM envelope is not doubled; no
  test-count regression.
