# Design: Phase 41 — Capture Engine

> Status: **Proposed**. Target tag: **v0.1.8**.

## Goal

Recording as a first-class source. ScreenCaptureKit for display / window / app capture; AVCaptureSession for webcam + microphone; encode-while-recording via VideoToolbox; streamed fragmented `.mov` written incrementally to a chunked file under the user-chosen location, so a crash loses at most the last chunk. Screen / webcam / mic / system audio land as SEPARATE tracks, never premixed.

## Prerequisites

- Capability tiers (not yet specced) — a probe that determines whether the hardware encoder can sustain the requested resolution + fps without dropping frames.
- Diagnostics (not yet specced) — surfaces probe results + live record stats.
- Sandbox entitlements: `com.apple.security.device.audio-input`, `com.apple.security.device.camera`, ScreenCaptureKit consent permissions. Requested only when the user opens the recorder.

## Approach

1. **Source acquisition.**
   - **Display / window / app:** ScreenCaptureKit `SCStream` with `SCStreamConfiguration` (resolution, fps, audio yes/no).
   - **Webcam:** `AVCaptureDevice.discoverySession(deviceTypes: [.builtInWideAngleCamera, .external])` + `AVCaptureSession` + `AVCaptureVideoDataOutput`.
   - **Microphone:** `AVCaptureDevice` + `AVCaptureAudioDataOutput`.
   - **System audio:** ScreenCaptureKit's `captureAudio = true` on macOS 13+; routed as a separate track.
2. **Encode-while-record.** Each source feeds an `AVAssetWriter` configured with VideoToolbox `kVTCompressionPropertyKey_RealTime = true` and a target bitrate selected from the capability probe. Hardware encoder sessions are gated by the probe — exceeding the budget yields an explicit error before record starts.
3. **Chunked fragmented MP4.** Each writer produces a fragmented `.mov` written via `AVAssetWriter` with `shouldOptimizeForNetworkUse = true`. We rotate to a new chunk every N seconds (default 30 s) by closing one writer and opening the next, atomically. A `manifest.json` per session lists the chunks in order; recovery on next launch concatenates them losslessly via `AVMutableComposition` (no re-encode) into one timeline source per track.
4. **Storage.** Sessions write into `~/Movies/LocalCut Recordings/<session-uuid>/` under user-selected file access (sandbox). Preflight checks `URLResourceKey.volumeAvailableCapacityForImportantUsage`. A live monitor warns at 10% remaining and stops gracefully at 5%.
5. **Track alignment.** All writers use a shared `CMClock` (`CMClockGetHostTimeClock()`) so timestamps are mutually aligned within one audio quantum (≈ 21 µs at 48 kHz). On stop, the resulting `Project` lands the tracks at their captured presentation timestamps, not at zero — the alignment is preserved.
6. **Recovery.** On launch, scan `~/Movies/LocalCut Recordings/` for sessions whose `manifest.json` ends without a "stopped" marker. Offer them in the media bin as "Recovered session — N s recovered".
7. **Capability matrix.** ScreenCaptureKit system audio requires macOS 13+ on Apple Silicon; Intel Macs are limited. The capability probe in P26 (not yet specced) decides what to enable per host. Recording overall is an accelerated-tier feature in v1.

## Trade-offs

- ScreenCaptureKit (post-macOS 12.3) over legacy `CGDisplayStream`: better app / window targeting, lower CPU, system-audio support.
- Fragmented `.mov` over `.mkv`: AVFoundation writes and reads `.mov` natively; `.mkv` would need an external library.
- 30 s chunks balance recovery loss vs. file count; configurable.

## Risks

- ScreenCaptureKit consent UX shows the OS picker — we cannot pre-pick. UX must explain why a click is required.
- Sustained 4K60 capture can saturate the hardware encoder on baseline tier; the probe must be conservative.

## Non-goals

- Scene mixing (Phase 45).
- Live streaming out (Phase 47).
- Replay buffer (Phase 46).
- Cursor effects (Phase 43).
- Pause / resume UX polish (Phase 42).
