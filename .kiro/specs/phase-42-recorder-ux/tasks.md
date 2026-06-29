# Tasks: Phase 42 — Recorder UX

> Status: **Implemented**. Depends on Phase 41.

## Countdown + transport

- [x] **T1.1** Countdown modal with 3 / 5 / 10 s options + cancel.
- [x] **T1.2** Pause / resume wiring: stop stream + writer, open new chunk on resume; preserve PTS gap.
- [x] **T1.3** Documented "ripple-collapse gap" command.

## Source switching

- [x] **T2.1** Mid-session display / window / app switch via `SCStream.updateContentFilter(_:)` paired with a GPU scale/crop pass (Core Image / Metal) that maps every captured frame into the writer's FIXED canvas size set at session start. `AVAssetWriter` rejects appends whose dimensions change mid-stream, so the writer's encoded format never changes; if the user wants source-native dimensions on the next take, that's `retake`.
- [x] **T2.2** Drop the first frame post-switch.

## PiP layouts

- [x] **T3.1** Corner / size / mask presets for webcam-on-screen layouts.
- [x] **T3.2** Apply at timeline time only (no capture-time premix).

## Floating control strip

- [x] **T4.1** `NSPanel` host (non-activating, always-on-top) with SwiftUI content.
- [x] **T4.2** Source indicator, native source-switch menu, and live microphone peak meter when mic capture is active.
- [x] **T4.3** "Hide floating controls while recording" option.

## Region capture + retake

- [x] **T5.1** Transparent overlay window for region drag; lock-and-record with `SCStreamConfiguration.sourceRect`.
- [x] **T5.2** Retake command: replace most-recent chunk-set in the same timeline slot.

## Verification

- [x] **T6.1** Swift Testing coverage: record → pause → resume → stop manifest semantics and timeline gap/collapse behavior.
- [x] **T6.2** Floating-panel fallback verification: hidden panel still leaves main-window recording controls available.
- [x] **T6.3** Retake replacement, per-source track-index, and stale-PiP regression coverage; retake landing remains one undoable import operation.
- [x] **T6.4** `xcodebuild` (Debug, macOS) green.
