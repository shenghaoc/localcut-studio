# Design: Phase 34 — Beat Detection and Beat-Synced Editing (卡点)

> Status: **Complete**. Target tag: **v0.1.3**.

## Goal

Offline beat analysis of any audio source on a background actor, with results cached per source. Timeline UX: beat markers on the ruler, snap-to-beat in the snapping system, an "auto-cut selected clips to beats" command (split or align), and a global beat-offset nudge. Works on user-supplied audio only.

## Prerequisites

- Timeline markers — `TimelineMarker { kind, time, label }` rendered on the ruler with add/remove + keyboard.
- Project bundle / persistence layer (`feature-project-persistence`) — beat analysis is cached per source under the bundle's `Caches/` directory keyed by SHA-256 of the audio asset.

## Approach

1. **Analysis pipeline.** Background actor. Decode the source's audio track via `AVAssetReader` at 22.05 kHz mono (decimation is cheap and the spectral-flux step doesn't need full bandwidth). Compute STFT with `vDSP_fft_zrip` on 1024-sample windows with 50% overlap. Half-wave-rectified spectral flux gives onset strength. Pick peaks via adaptive thresholding (running median + delta). Estimate tempo via autocorrelation of the onset envelope and confirm a beat grid by dynamic-programming track-back.
2. **Output.** A `BeatAnalysis { tempoBPM, beatTimes: [CMTime], confidence: Float }` per source.
3. **Cache.** Store as a small binary blob under `Caches/beats/<sha256>.beat` (versioned header). Re-run only when the source's SHA-256 changes. Eligible for inclusion in the project bundle's `Caches/beats/` directory for portability.
4. **Marker integration.** `BeatAnalysis.beatTimes` are SOURCE-relative (relative to the audio file's start, not the timeline). For ruler markers, snap targets, and cut-at-beats we project per clip through the clip's source-to-timeline mapping:
   ```
   timelineBeat = clip.timelineStart + clip.mapSourceTimeToTimeline(sourceBeat − clip.sourceStart)
   ```
   This handles trims (sourceStart ≠ 0), re-use (the same audio file placed twice on the timeline emits two separate sets of timeline markers), and Phase 35 retimes (the mapping is the identity when no ramp, the speed-curve evaluator when there is one). Beat markers don't render in export and re-project automatically when the underlying clip moves or is retimed.
5. **Snap-to-beat.** Extend the existing snapping system with a beat-targets source; the snap radius and snap toggle reuse the UX from clip-edge snapping (in `feature-timeline-trim-and-drag`).
6. **Auto-cut to beats.** A command that operates on the current selection — either `split` (cut clips at every in-range beat) or `align` (move clip start to the nearest beat within a configurable window). Fully undoable.
7. **Global offset.** A bus offset slider (±200 ms) applied at marker draw time and at snap time, without re-running analysis.

## Engine boundary (honours `feature-localcutcore-package` / PR #37)

The pure, deterministic engine — `BeatDetectionCore` (vDSP STFT, onset peak
picking, autocorrelation tempo + octave correction, DP beat track-back, CMTime
quantisation), the `BeatAnalysis` model, `ProjectedBeatMarker`, `BeatAnalysisError`,
and the versioned `BeatAnalysisCache` — lives in
`Packages/LocalCutCore/Sources/LocalCutCore/Beats/`. It builds and tests without
SwiftUI/AVFoundation (`swift test --package-path Packages/LocalCutCore`). Only the
AVFoundation decode (`BeatAnalyzer.decodeMonoSamples`, `AVAssetReader` at
22.05 kHz mono) stays in the app target and feeds `[Float]` samples into the core.
This is the same client-compute split the rest of the engine follows.

## Marker rendering and the projected-beat memo

Beat markers are a **projected overlay** (`ProjectedBeatMarker { id, time }`), not
a stored `TimelineMarker` kind: they are derived from analysis, re-project per
clip whenever geometry changes, can number in the thousands, and must not export —
all reasons they don't belong in the authored-marker model. `projectedBeatTimes()`
(the union across all clips, used by the ruler, snap targets, and Align) is
memoised behind a revision counter for the hot ruler-draw path. The memo is
invalidated at every input: `didSet` on `beatOffsetSeconds` and `beatAnalyses`,
and one `invalidateProjectedBeatTimesCache()` in `scheduleRebuild()` — the
chokepoint every clip-geometry edit (trim/move/split/delete/cut/align/undo/redo/
reload) passes through. Playhead-only redraws don't rebuild, so the memo still
spares the common case. "Cut at beats" deliberately bypasses the union and uses
the selected clip's *own* analysis, so an overlapping clip's beats can't bleed in.

## Trade-offs

- vDSP/Accelerate vs WASM-SIMD (browser equivalent): we have first-class CPU SIMD on Apple Silicon — no WASM bridge needed.
- Spectral flux + autocorrelation is robust on percussive material and reasonable on melodic material; a tracker like BeatRoot is more elaborate but out of scope for v1.
- Mono decimation loses some onset cues for sparse music but halves the compute and is still well above the realtime bar.

## Risks

- Sample rates with non-standard timescales — clamp to `CMTimeMake(value, 600)` when emitting marker times; never trust source asset timescale blindly.
- Audio-only sources (e.g. `.m4a` purchased from a store) may carry DRM that `AVAssetReader` cannot open — fail with a user-visible message, do not crash.

## Non-goals

- Bundled music or sound library (licensing).
- Genre / downbeat classification (ML).
- Live-input beat tracking.

## Defects fixed during bring-up (folded from `bugfix-phase-34-beat-ci`)

The hosted `Test (macOS 26 / Xcode)` parallel-worker job caught three defects the
local `xcodebuild test` run did not; a fourth followed from the estimator change.
B1/B2 were raised in PR #40 automated review and merged unfixed — the lesson
(mirroring `bugfix-build-warnings-and-modernization`) is that the hosted job is
the authoritative gate and unresolved P1/P2 threads should block merge.

- **B1 — real-FFT buffer overrun (crash).** `onsetEnvelope` packs `frameSize`
  (1024) real samples into `halfN` (512) split-complex elements via `vDSP_ctoz`
  with `realp`/`imagp` allocated to `halfN`, but called the **full-complex**
  `vDSP_fft_zip` (which reads/writes 2¹⁰ = 1024 elements), overrunning the
  allocations and hard-crashing the xctest worker — which marked ~280 unrelated
  queued tests as failed in 0.000 s. Fix: call the real in-place `vDSP_fft_zrip`,
  which operates on exactly the `halfN` packed elements the FFT setup was created
  for. `zrip` packs DC in `realp[0]` / Nyquist in `imagp[0]`, an acceptable
  approximation for a spectral-flux envelope and deterministic.
- **B2 — spurious leading beat.** `dpBeatTrack` seeded its grid at
  `firstPeakTime.truncatingRemainder(dividingBy: interval)` (the bare phase),
  which is `0.0` when the first onset lands on an integer multiple of the
  interval, emitting a beat at `t = 0` in leading silence and shifting every
  subsequent index. Fix: anchor the grid on `firstPeakTime` itself (a valid grid
  position), dropping the pre-roll beat.
- **B3 — tempo locks onto the sub-harmonic (half tempo).** Integer-lag
  autocorrelation on a non-integer beat period (the 120 BPM fixture's beats fall
  every 21.53 frames) aligns best with an integer *multiple* of the period —
  lag 43 (≈2 beats) beats lag 21/22 — so the bare peak reports ~60 BPM. Fix: after
  the peak, if a lag near `bestLag/2` or `bestLag/3` retains ≥
  `octaveEnergyFraction` (0.5) of the peak's **raw** onset energy, step down to
  that faster fundamental; loop for deeper sub-harmonics. Candidates are an
  ordered `[lower, upper]` list with a strict-`>` tie rule (deterministic, no
  `Set`). Verified: 120 BPM fixture → 117.45 BPM (within ±5); `tempoEstimate`
  (exact 10-frame period) stays 120; a genuine 60 BPM envelope stays 60. The
  `/(count-lag)` normalisation is preserved (it's what keeps the integer-period
  case on the fundamental).
- **B4 — stale `.beat` caches survive the estimator change.** Blobs are
  SHA-keyed and served before re-analysing, so a project that cached the B3
  half-tempo result would keep showing ~60 BPM. Fix: bump
  `BeatAnalysisCache.version` 1 → 2; the decode guard rejects v1 blobs and forces
  re-analysis. Round-trip tests encode/decode with the same version, so they are
  unaffected.
