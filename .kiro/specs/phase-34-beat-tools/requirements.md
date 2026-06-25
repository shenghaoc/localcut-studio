# Requirements: Phase 34 — Beat Detection and Beat-Synced Editing

> Status: **All met.** See `tasks.md` for the per-task mapping and the folded
> `bugfix-phase-34-beat-ci` defects (B1–B4).

## R1 — Analysis

- **R1.1** Beat analysis runs on a background actor (off the main actor); the UI remains interactive throughout.
- **R1.2** Analysis is faster than realtime: a 5-minute 48 kHz track analyses in ≤2.5 minutes on a baseline-tier Mac.
- **R1.3** Output: `BeatAnalysis { tempoBPM: Double, beatTimes: [CMTime], confidence: Float }`.
- **R1.4** Identical sources yield identical analyses (deterministic).

## R2 — Cache

- **R2.1** Analysis is cached per audio source keyed by SHA-256 of the file contents.
- **R2.2** The cache lives under the project bundle's `Caches/beats/` and ships with bundle export/import.
- **R2.3** A versioned header allows future format changes without orphaning old caches.

## R3 — Timeline integration

- **R3.1** Beat markers render on the ruler as thin verticals with a distinct colour; they do not export.
- **R3.2** Snap-to-beat is a toggle in the snapping settings; respects the existing snap radius from `feature-timeline-trim-and-drag`.
- **R3.3** Global beat offset (±200 ms) applies at draw and snap time without re-running analysis.

## R4 — Editing commands

- **R4.1** "Cut at beats" splits selected clips at every beat in their range; fully undoable.
- **R4.2** "Align to beat" moves each selected clip's start to the nearest beat within a user-set window; fully undoable.
- **R4.3** A failed analysis (DRM, corrupt file) does not block editing; an error appears in `statusMessage`.

## R5 — Verification

- **R5.1** Unit tests for onset peak picking, tempo estimation, and `CMTime` quantisation on fixture envelopes.
- **R5.2** Determinism test: analysing the same fixture twice yields identical `beatTimes`.
- **R5.3** Smoke: import audio → analyse → markers appear → cut-at-beats → undo → save bundle → reopen → cache present, markers reload.
- **R5.4** `xcodebuild` green; no test count regression.
