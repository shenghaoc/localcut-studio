# Requirements: Phase 41 — Capture Engine

## R1 — Sources

- **R1.1** Display, window, and app capture via ScreenCaptureKit.
- **R1.2** Webcam capture via AVCaptureSession with device picker; honours external cameras as well as built-in.
- **R1.3** Microphone capture via AVCaptureSession.
- **R1.4** System audio via ScreenCaptureKit's audio track on supported hosts; surfaced as a separate track.
- **R1.5** Missing camera, microphone, screen-recording, or recordings-folder permission surfaces a user-visible status / recovery action; no silent failure and no speculative entitlements beyond the APIs this phase uses.

## R2 — Encoding

- **R2.1** VideoToolbox encoder sessions are gated by `Capabilities.tier(for: .simultaneousCaptureStreams(count:))` plus the Phase 41 per-source resolution / fps preflight; exceeding either budget yields an explicit error before record starts.
- **R2.2** Each source writes its own track; tracks are never premixed.
- **R2.3** Frame timestamps share a common `CMClock` (`CMClockGetHostTimeClock()`); mutual alignment within one audio quantum (≈ 21 µs at 48 kHz).
- **R2.4** Session start captures a `sessionStartHostTime` snapshot of that clock; on landing, clips appear on the timeline at `(capturedPTS − sessionStartHostTime)` so the result starts at zero on the project timeline. Inter-track alignment is preserved exactly because every writer subtracts the same offset.
- **R2.5** Writer inputs use bounded buffering. Sustained writer backpressure records a manifest event and surfaces a warning / graceful stop rather than growing memory without bound.

## R3 — Fragmented output

- **R3.1** Each track writes ONE continuous fragmented `.mov` with `movieFragmentInterval` set (default 2 s); fragments flush during write rather than only at finalisation.
- **R3.2** `manifest.ndjson` is an append-only event log (one JSON object per line, never rewritten). Record kinds in v1: `header`, `epoch`, `source-ended`, `backpressure`, `finalize`. Phase 45 extends with `scene-doc` / `scene-switch`; unknown kinds are skipped on read so the format is forward-compatible.
- **R3.3** A crash (app kill / power loss) leaves each source's `.mov` readable up to the last flushed fragment — loss is bounded by the fragment interval, not by a chunk boundary.
- **R3.4** Manifest readers ignore a partial trailing line and keep the valid prefix, so a kill during an append cannot poison recovery.

## R4 — Storage

- **R4.1** Sessions write to `~/Movies/LocalCut Recordings/<uuid>/` under user-selected sandbox access.
- **R4.2** Preflight checks volume capacity; warns at 10% remaining, stops gracefully at 5%.
- **R4.3** Recovery on launch scans for sessions whose `manifest.ndjson` ends without a `finalize` record and offers them in the media bin.
- **R4.4** The recordings-root security-scoped bookmark is persisted in app settings, resolved before recovery, refreshed when stale, and re-bindable through Preferences.
- **R4.5** Clean stops and recovered sessions land as normal media items, one timeline track per source, in one undoable "Add Recording" action.

## R5 — Capability

- **R5.1** The hardware encoder probe limits simultaneous encoder sessions and the maximum per-source resolution + fps.
- **R5.2** ScreenCaptureKit system-audio availability is feature-detected per macOS version + chip family.
- **R5.3** Recording is gated to the accelerated tier in v1; baseline-tier hardware sees a clear "not supported on this Mac" message. Multi-source sessions requiring 3+ simultaneous video encoders require a pro-tier verdict.
- **R5.4** Recorder live stats publish through the existing diagnostics/status surfaces: source count, dropped/backpressured frames, current duration, disk remaining estimate, and recovery state.

## R6 — Verification

- **R6.1** 30-minute 1080p recording with bounded memory (mocked-buffer tests; no per-fragment file count growth on disk).
- **R6.2** Recovery test: simulated process kill mid-record → next launch surfaces the partial session, with each `.mov` readable up to the last flushed fragment.
- **R6.3** Alignment test: 2-source capture → resulting tracks aligned within one audio quantum at the start.
- **R6.4** Manifest parser tests cover unknown record kinds and truncated trailing lines.
- **R6.5** Capability tests cover accelerated vs. pro capture-stream gates and the user-visible baseline-tier rejection path.
- **R6.6** `xcodebuild` (Debug, macOS) green; no test count regression.
