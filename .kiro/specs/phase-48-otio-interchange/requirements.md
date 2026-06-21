# Requirements: Phase 48 — OpenTimelineIO Export

## R1 — Time model

- **R1.1** `interchangeRate(doc)` picks `project.frameRate` when finite > 0, else most common source fps, else 30.
- **R1.2** Each boundary snaps independently; durations derive from `endFrames − startFrames`.
- **R1.3** Adjacent clips stay adjacent in frames after snapping; no spurious gaps or overlaps.
- **R1.4** Fractional rates (23.976, 29.97) preserve exact rational representation.
- **R1.5** Zero-frame clips and orphan transitions are dropped with warnings; never silently emitted.
- **R1.6** Micro-gap collapse: gaps below `max(1 ms, 0.5 / interchangeRate)` snap to zero before emission so floating-point rounding never produces a stray 1-frame black flash on read in another NLE.

## R2 — Schema

- **R2.1** Emit only the documented schema allowlist (`Timeline.1`, `Stack.1`, `Track.1`, `Clip.2`, `Gap.1`, `Transition.1`, `Marker.2`, `ExternalReference.1`, `GeneratorReference.1`, `MissingReference.1`, `RationalTime.1`, `TimeRange.1`).
- **R2.2** Every emitted document validates against a structural validator in CI.

## R3 — Mapping

- **R3.1** Project metadata + tracks + clips + gaps + transitions + markers map per the design table.
- **R3.2** LocalCut-specific fields (effects, transforms, keyframes, LUT refs, fades, caption styling, layout tracks) nest under `metadata.localcut`.
- **R3.3** Media references carry the file fingerprint (SHA-256) in metadata for future re-linking.
- **R3.4** Missing media emits `MissingReference.1` with the original file name preserved.

## R4 — Determinism

- **R4.1** Identical `ProjectDoc` + options yield byte-identical `.otio` output across runs.
- **R4.2** Golden fixtures compare byte-for-byte in CI.

## R5 — CMX3600 EDL

- **R5.1** Single-video-track per list with record TC starting at `01:00:00:00`.
- **R5.2** Reel names ≤ 8 chars uppercase-alphanumeric; deterministic dedup.
- **R5.3** Fractional rate adds a `* LOCALCUT: RATE` comment.
- **R5.4** Transitions on the exported track become straight cuts with a warning per omission.
- **R5.5** EDL passes a CMX3600 line-grammar validator in CI.

## R6 — Bundle integration

- **R6.1** `project.otio` lands at the bundle root alongside `project.json`.
- **R6.2** `project.json` stays authoritative; bundle import does NOT read `project.otio`.
- **R6.3** Serialisation failure → warning-severity integrity item; bundle export still succeeds.

## R7 — Verification

- **R7.1** Unit tests for time math, schema validity, mapping correctness, EDL grammar.
- **R7.2** Golden `.otio` + `.edl` fixtures in `Tests/Fixtures/Interchange/`.
- **R7.3** CI step installs Python `opentimelineio` and parses each golden with the reference library.
- **R7.4** Documented manual verification checklist for Kdenlive 25.04+ and DaVinci Resolve.
- **R7.5** `xcodebuild` (Debug, macOS) green; no test count regression.
