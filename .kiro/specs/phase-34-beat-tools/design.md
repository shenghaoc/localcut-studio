# Design: Phase 34 — Beat Detection and Beat-Synced Editing (卡点)

> Status: **Proposed**. Target tag: **v0.1.3**.

## Goal

Offline beat analysis of any audio source on a background actor, with results cached per source. Timeline UX: a "beat" marker kind on the ruler, snap-to-beat in the snapping system, an "auto-cut selected clips to beats" command (split or align), and a global beat-offset nudge. Works on user-supplied audio only.

## Prerequisites

- Timeline markers (not yet specced) — `TimelineMarker { kind, time, label }` rendered on the ruler with add/remove + keyboard.
- Project bundle / persistence layer (`feature-project-persistence`) — beat analysis is cached per source under the bundle's `Caches/` directory keyed by SHA-256 of the audio asset.

## Approach

1. **Analysis pipeline.** Background actor. Decode the source's audio track via `AVAssetReader` at 22.05 kHz mono (decimation is cheap and the spectral-flux step doesn't need full bandwidth). Compute STFT with `vDSP_fft_zrip` on 1024-sample windows with 50% overlap. Half-wave-rectified spectral flux gives onset strength. Pick peaks via adaptive thresholding (running median + delta). Estimate tempo via autocorrelation of the onset envelope and confirm a beat grid by dynamic-programming track-back.
2. **Output.** A `BeatAnalysis { tempoBPM, beatTimes: [CMTime], confidence: Float }` per source.
3. **Cache.** Store as a small binary blob under `Caches/beats/<sha256>.beat` (versioned header). Re-run only when the source's SHA-256 changes. Eligible for inclusion in the project bundle's `cache/` directory for portability.
4. **Marker integration.** `BeatAnalysis.beatTimes` are SOURCE-relative (relative to the audio file's start, not the timeline). For ruler markers, snap targets, and cut-at-beats we project per clip through the clip's source-to-timeline mapping:
   ```
   timelineBeat = clip.timelineStart + clip.mapSourceTimeToTimeline(sourceBeat − clip.sourceStart)
   ```
   This handles trims (sourceStart ≠ 0), re-use (the same audio file placed twice on the timeline emits two separate sets of timeline markers), and Phase 35 retimes (the mapping is the identity when no ramp, the speed-curve evaluator when there is one). Beat markers don't render in export and re-project automatically when the underlying clip moves or is retimed.
5. **Snap-to-beat.** Extend the existing snapping system with a beat-targets source; the snap radius and snap toggle reuse the UX from clip-edge snapping (in `feature-timeline-trim-and-drag`).
6. **Auto-cut to beats.** A command that operates on the current selection — either `split` (cut clips at every in-range beat) or `align` (move clip start to the nearest beat within a configurable window). Fully undoable.
7. **Global offset.** A bus offset slider (±200 ms) applied at marker draw time and at snap time, without re-running analysis.

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
