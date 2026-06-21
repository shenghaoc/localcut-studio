# Tasks: Phase 42 — Recorder UX

> Status: **Proposed**. Depends on Phase 41.

## Countdown + transport

- [ ] **T1.1** Countdown modal with 3 / 5 / 10 s options + cancel.
- [ ] **T1.2** Pause / resume wiring: stop stream + writer, open new chunk on resume; preserve PTS gap.
- [ ] **T1.3** Documented "ripple-collapse gap" command.

## Source switching

- [ ] **T2.1** Mid-session display / window / app switch via `SCStream.updateContentFilter(_:)`.
- [ ] **T2.2** Drop the first frame post-switch.

## PiP layouts

- [ ] **T3.1** Corner / size / mask presets for webcam-on-screen layouts.
- [ ] **T3.2** Apply at timeline time only (no capture-time premix).

## Floating control strip

- [ ] **T4.1** `NSPanel` host (non-activating, always-on-top) with SwiftUI content.
- [ ] **T4.2** Source indicators + mic meter.
- [ ] **T4.3** "Hide while recording" option.

## Region capture + retake

- [ ] **T5.1** Transparent overlay window for region drag; lock-and-record.
- [ ] **T5.2** Retake command: replace most-recent chunk-set in the same timeline slot.

## Verification

- [ ] **T6.1** XCUITest: record → pause → resume → stop → timeline gap correct.
- [ ] **T6.2** Floating-panel fallback test.
- [ ] **T6.3** Retake undo test.
- [ ] **T6.4** `xcodebuild` (Debug, macOS) green.
