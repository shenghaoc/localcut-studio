# Design: Phase 42 — Recorder UX

> Status: **Implemented**. Target tag: **v0.1.9**.

## Goal

Polish the recorder flow: countdown, pause / resume with defined timestamp-gap semantics, mid-session source switching, webcam picture-in-picture layouts, a floating control strip that follows the user out of the main window, region capture for own-window demos, and a "retake" flow that lands the replacement straight into the same timeline slot.

## Prerequisites

- Phase 41 capture engine.

## Approach

1. **Countdown.** A modal pre-roll with 3 / 5 / 10 second options; cancellable; fires the actual capture start when it reaches zero.
2. **Pause / resume.** ScreenCaptureKit `SCStream.stopCapture()` + `startCapture()` cycle. The gap is recorded as a timestamp jump on the resulting track — clips land at their captured PTS, so the timeline shows a gap, NOT a stitched continuous clip. This is documented and explicit; users can collapse the gap with an existing ripple edit if they want.
3. **Mid-session source switching.** The user can swap a display / window / app target during record. ScreenCaptureKit supports `SCStream.updateConfiguration(_:)` for the resolution / fps fields and `SCStream.updateContentFilter(_:)` for the target. **`AVAssetWriter` fixes its input's encoded width/height at session start** — appending samples whose dimensions change mid-stream produces an invalid file. So the switch path keeps the writer's encoded format STABLE: a scale/crop pass on the GPU (Core Image / Metal) maps every captured frame into the writer's fixed canvas before append, regardless of the source's native size. If the user wants source-native dimensions on the next take, that requires stopping + retaking (Phase 42's `retake` flow), not mid-session swap.
4. **PiP layout presets.** Webcam-as-overlay layouts for a screen recording: corner picker, size picker, optional circular mask. PiP composition happens at the timeline level (separate tracks, transforms applied at render), NOT at capture time — keeping ISO tracks faithful.
5. **Floating control strip.** A separate `NSPanel`-class window (non-activating) floats above all apps with stop / pause / resume, a source-count indicator, source-switch menu, and a live microphone peak meter when microphone capture is active. ScreenCaptureKit captures any window that's on screen during record, so the strip must be invisible to the capture: we pass the panel's `CGWindowID` to `SCContentFilter.init(display:excludingWindows:)` (or the equivalent app-capture exclusion list) for the lifetime of the session. The strip also offers an explicit "Hide floating controls while recording" toggle that adds belt-and-braces by hiding the panel altogether after its window ID has been excluded. Closed or hidden returns control to the main-window toolbar.
6. **Region capture.** ScreenCaptureKit's `SCStreamConfiguration.sourceRect` scopes a display stream to the selected sub-region while the writer uses the crop's fixed pixel dimensions. A transparent overlay window lets the user drag a rectangle; the recorder locks that rectangle into the capture request.
7. **Retake.** While the recorder is open over an existing session, "retake" replaces the most recent stop's chunk-set with a fresh start. The replacement lands at the same timeline position; undoable.

## Trade-offs

- Floating panel via `NSPanel` (AppKit) rather than a SwiftUI window: panel windows have the right behaviour (non-activating, always-on-top).
- Document Picture-in-Picture (browser concept) does not have a direct macOS analog — the floating `NSPanel` is the equivalent.
- PiP composition at timeline-time (not capture-time) loses the convenience of a baked overlay but preserves edit flexibility.

## Risks

- A floating panel on top of a fullscreen app can interfere with that app's input; document and offer "hide while recording" as an option.
- Source switching mid-record can introduce a small content-jump frame; we drop the first frame after switch to keep the cut clean.

## Non-goals

- Global OS hotkeys.
- Full audio monitoring UI beyond the recorder microphone peak meter.
- Multi-monitor mosaic capture in one session.
