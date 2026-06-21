# Requirements: Phase 41 — Capture Engine

## R1 — Sources

- **R1.1** Display, window, and app capture via ScreenCaptureKit.
- **R1.2** Webcam capture via AVCaptureSession with device picker; honours external cameras as well as built-in.
- **R1.3** Microphone capture via AVCaptureSession.
- **R1.4** System audio via ScreenCaptureKit's audio track on supported hosts; surfaced as a separate track.

## R2 — Encoding

- **R2.1** VideoToolbox encoder sessions are gated by the capability probe (R5); exceeding the budget yields an explicit error before record starts.
- **R2.2** Each source writes its own track; tracks are never premixed.
- **R2.3** Frame timestamps share a common `CMClock`; mutual alignment within one audio quantum (≈ 21 µs at 48 kHz).

## R3 — Chunked output

- **R3.1** Each track writes ONE continuous fragmented `.mov` with `movieFragmentInterval` set (default 2 s); fragments flush during write rather than only at finalisation.
- **R3.2** A `manifest.json` per session lists source IDs, file paths, encoder configs, and a "stopped" marker on clean shutdown.
- **R3.3** A crash (app kill / power loss) leaves each source's `.mov` readable up to the last flushed fragment — loss is bounded by the fragment interval, not by a chunk boundary.

## R4 — Storage

- **R4.1** Sessions write to `~/Movies/LocalCut Recordings/<uuid>/` under user-selected sandbox access.
- **R4.2** Preflight checks volume capacity; warns at 10% remaining, stops gracefully at 5%.
- **R4.3** Recovery on launch scans for sessions without a "stopped" marker and offers them in the media bin.

## R5 — Capability

- **R5.1** The hardware encoder probe limits simultaneous encoder sessions and the maximum per-source resolution + fps.
- **R5.2** ScreenCaptureKit system-audio availability is feature-detected per macOS version + chip family.
- **R5.3** Recording is gated to the accelerated tier in v1; baseline-tier hardware sees a clear "not supported on this Mac" message.

## R6 — Verification

- **R6.1** 30-minute 1080p recording with bounded memory (mocked-buffer tests; no per-fragment file count growth on disk).
- **R6.2** Recovery test: simulated process kill mid-record → next launch surfaces the partial session, with each `.mov` readable up to the last flushed fragment.
- **R6.3** Alignment test: 2-source capture → resulting tracks aligned within one audio quantum at the start.
- **R6.4** `xcodebuild` (Debug, macOS) green; no test count regression.
