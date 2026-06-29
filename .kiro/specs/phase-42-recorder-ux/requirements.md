# Requirements: Phase 42 — Recorder UX

> Status: **Implemented**.

## R1 — Countdown

- **R1.1** Pre-roll modal with 3 / 5 / 10 second options; cancellable.
- **R1.2** Capture starts at zero; first frame timestamp uses the host clock at that moment.

## R2 — Pause / resume

- **R2.1** Pause stops capture and the writer; resume opens a new chunk.
- **R2.2** Resulting track preserves the wall-clock gap (clips land at their captured PTS); the timeline displays the gap explicitly.
- **R2.3** A documented "ripple-collapse gap" command merges the two segments to a single continuous clip if the user requests it.

## R3 — Source switching

- **R3.1** The user can swap display / window / app target without stopping the writer.
- **R3.2** The first frame after the switch is dropped to avoid a content-jump fragment.

## R4 — PiP layouts

- **R4.1** Layout presets for a webcam-on-top-of-screen recording: corner + size + optional circular mask.
- **R4.2** PiP composition is timeline-level: ISO tracks remain unpremixed.

## R5 — Floating control strip

- **R5.1** A non-activating, always-on-top panel hosts stop / pause / resume, source indicators, source switching, and a microphone peak meter when microphone capture is active.
- **R5.2** Closing the panel returns control to the main window.
- **R5.3** The panel's `CGWindowID` is passed to `SCContentFilter.init(display:excludingWindows:)` for the lifetime of every display / window / app capture session, so ScreenCaptureKit never burns the strip into the recorded frames — independent of whether the user keeps it visible.
- **R5.4** "Hide while recording" option is offered as a user preference on top of R5.3 (belt-and-braces).

## R6 — Region capture + retake

- **R6.1** Region capture: drag a rectangle on screen; `SCStreamConfiguration.sourceRect` samples that region and the writer records the crop's fixed pixel dimensions.
- **R6.2** Retake: a "retake" command replaces the most-recent chunk-set; the replacement lands at the same timeline slot; undoable.

## R7 — Verification

- **R7.1** Swift Testing regression coverage for record → pause → resume → stop manifest semantics and the timeline gap/collapse behavior.
- **R7.2** Floating-panel fallback verification: panel hidden → main-window toolbar controls remain the canonical start / stop / pause path.
- **R7.3** Retake verification covers same-slot replacement and per-source track ordering; the retake import remains registered as one undoable operation.
- **R7.4** `xcodebuild` (Debug, macOS) green; no test count regression.
