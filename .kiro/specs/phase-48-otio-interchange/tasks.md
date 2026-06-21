# Tasks: Phase 48 — OpenTimelineIO Export

> Status: **Proposed**. Depends on `feature-project-persistence`, markers spec.

## Time model

- [ ] **T1.1** `Interchange/Time.swift` — `interchangeRate`, `snapToFrames`, boundary durations, `formatTimecode`.
- [ ] **T1.2** Unit tests for fractional rates, adjacency, snap rounding.

## OTIO emitter

- [ ] **T2.1** `Interchange/OtioNodes.swift` — plain Swift structs for the schema allowlist.
- [ ] **T2.2** `Interchange/OtioSerializer.swift` — `serializeTimelineToOtio(doc, options) -> (text, warnings)`.
- [ ] **T2.3** `Interchange/OtioValidator.swift` — structural validator used by tests + CI.
- [ ] **T2.4** Drop-and-warn paths for zero-frame clips + orphan transitions.

## EDL emitter

- [ ] **T3.1** `Interchange/EdlSerializer.swift` — CMX3600 emitter sharing `Time.swift`.
- [ ] **T3.2** CMX3600 line-grammar validator (test-only).

## Bundle integration

- [ ] **T4.1** Add `PROJECT_OTIO_PATH = "project.otio"` to the bundle path constants.
- [ ] **T4.2** Write `project.otio` after `project.json` in bundle export.
- [ ] **T4.3** Warning-severity integrity item on serialisation failure; bundle still succeeds.

## UI

- [ ] **T5.1** "Export Timeline (.otio)" menu action with save panel.
- [ ] **T5.2** "Export EDL (.edl)" menu action with track picker + warnings display.

## CI / docs

- [ ] **T6.1** Golden `.otio` + `.edl` fixtures under `Tests/Fixtures/Interchange/`.
- [ ] **T6.2** Python `opentimelineio` reference-validation CI step.
- [ ] **T6.3** `docs/VERIFY_INTERCHANGE.md` — manual checklist for Kdenlive + Resolve + EDL tools.
- [ ] **T6.4** `docs/USER-GUIDE.md` — interchange section + `otioconvert` path for AAF / FCPXML.

## Verification

- [ ] **T7.1** Unit tests for all of the above.
- [ ] **T7.2** Golden byte-equality + reference validation in CI.
- [ ] **T7.3** `xcodebuild` (Debug, macOS) green.
