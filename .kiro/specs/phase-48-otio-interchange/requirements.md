# Requirements: Phase 48 — OpenTimelineIO Export

## R1 — Time model

- **R1.1** `interchangeRate(doc)` picks `project.frameRate` when finite > 0, else 30. The persisted media reference model does not currently store source FPS.
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
- **R3.2** LocalCut-specific fields (effects, transforms, keyframes, LUT refs, fades, caption styling, layout tracks, **Phase 35 speed curves**) nest under `metadata.localcut`.
- **R3.2a** Speed-ramped clips additionally adjust their emitted `source_range` to reflect the AVERAGE ramp ratio so foreign tools that ignore `metadata.localcut` still receive a clip of approximately the correct output duration. Non-uniform curves emit a warning per clip so the user knows variation won't round-trip into tools that don't honour our namespace.
- **R3.3** Media references carry the file fingerprint (SHA-256) in metadata when the export path has a resolved fingerprint, including bundle-generated `project.otio`.
- **R3.4** Missing media emits `MissingReference.1` with the original file name preserved.

## R4 — Determinism

- **R4.1** Identical `ProjectDoc` + options yield byte-identical `.otio` output across runs.
- **R4.2** Generated serializer output compares byte-for-byte across repeated calls; committed fixtures are reference-validated in CI.

## R5 — CMX3600 EDL

- **R5.1** Single-video-track per list with record TC starting at `01:00:00:00`.
- **R5.2** Reel names ≤ 8 chars uppercase-alphanumeric; deterministic dedup.
- **R5.3** Fractional rate adds a `* LOCALCUT: RATE` comment.
- **R5.4** Transitions on the exported track become straight cuts with a warning per omission.
- **R5.5** EDL passes a CMX3600 line-grammar validator in CI.
- **R5.6** Timelines with more than 999 emitted EDL events fail serialization with a user-visible error instead of writing a non-CMX3600-valid file.

## R6 — Bundle integration

- **R6.1** `project.otio` lands at the bundle root alongside `project.json`.
- **R6.2** `project.json` stays authoritative; bundle import does NOT read `project.otio`.
- **R6.3** Serialisation or sidecar-write failure is non-fatal; bundle export still succeeds and stale `project.otio` sidecars are removed instead of left behind.

## R7 — Verification

- **R7.1** Unit tests for time math, schema validity, mapping correctness, EDL grammar.
- **R7.2** Committed `.otio` + `.edl` fixtures live in `Tests/Fixtures/Interchange/`: `basic.otio`, `basic.edl`, `fractional.otio`, `fractional.edl`, `transitions.otio`, `missing_media.otio`, `markers.otio`, `speed_ramp.otio`, `localcut_metadata.otio`. Tests byte-compare fresh serializer output against every committed fixture.
- **R7.3** CI step installs Python `opentimelineio` and parses each committed `.otio` fixture with the reference library.
- **R7.4** Documented manual verification checklist for Kdenlive 25.04+ and DaVinci Resolve.
- **R7.5** `xcodebuild` (Debug, macOS) green; no test count regression.
