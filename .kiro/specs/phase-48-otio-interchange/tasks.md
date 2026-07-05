# Tasks: Phase 48 — OpenTimelineIO Export

> Status: **Implemented**. Depends on `feature-project-persistence`, markers, and project bundles.

## Time model

- [x] **T1.1** `Interchange/Time.swift` — `interchangeRate`, `snapToFrames`, boundary durations, `formatTimecode`.
- [x] **T1.2** Unit tests for fractional rates, adjacency, snap rounding.

## OTIO emitter

- [x] **T2.1** `Interchange/OtioNodes.swift` — plain Swift structs for the schema allowlist.
- [x] **T2.2** `Interchange/OtioSerializer.swift` — `serializeTimelineToOtio(doc, options) -> (text, warnings)`.
- [x] **T2.3** `Interchange/OtioValidator.swift` — structural validator used by tests + CI.
- [x] **T2.4** Drop-and-warn paths for zero-frame clips + orphan transitions.

## EDL emitter

- [x] **T3.1** `Interchange/EdlSerializer.swift` — CMX3600 emitter sharing `Time.swift`.
- [x] **T3.2** CMX3600 line-grammar validator (test-only).
- [x] **T3.3** Refuse >999-event EDL exports with a serialization failure before writing a non-CMX3600-valid file.

## Bundle integration

- [x] **T4.1** Add `ProjectBundleLayout.projectOTIO = "project.otio"` to the bundle path constants.
- [x] **T4.2** Write `project.otio` after `project.json` in bundle export.
- [x] **T4.3** Treat OTIO serialisation failure as non-fatal; bundle still succeeds without `project.otio`.

## UI

- [x] **T5.1** "Export Timeline (.otio)" menu action with save panel.
- [x] **T5.2** "Export EDL (.edl)" menu action with track picker + warnings display.

## CI / docs

- [x] **T6.1** Committed `.otio` + `.edl` fixtures under `Tests/Fixtures/Interchange/`: `basic.otio`, `basic.edl`, `fractional.otio`, `fractional.edl`, `transitions.otio`, `missing_media.otio`, `markers.otio`, `speed_ramp.otio`, `localcut_metadata.otio`. Byte-equality tests compare fresh serializer output against every committed fixture.
- [x] **T6.2** Python `opentimelineio` reference-validation CI step for committed `.otio` fixtures.
- [x] **T6.3** `docs/VERIFY_INTERCHANGE.md` — manual checklist for Kdenlive + Resolve + EDL tools.
- [x] **T6.4** `docs/USER-GUIDE.md` — interchange section + `otioconvert` path for AAF / FCPXML.

## Verification

- [x] **T7.1** Unit tests for all of the above.
- [x] **T7.2** Generated-output byte-equality tests + committed fixture reference validation in CI.
- [x] **T7.3** `xcodebuild` (Debug, macOS) green.
