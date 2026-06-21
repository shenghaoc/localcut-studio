# Design: Phase 41 — Capture Engine

> Status: **Proposed**. Target tag: **v0.1.8**.

## Goal

Recording as a first-class source. ScreenCaptureKit for display / window / app capture; AVCaptureSession for webcam + microphone; encode-while-recording via VideoToolbox; one continuous **fragmented** `.mov` per source streamed incrementally to disk so a crash loses at most the last un-flushed fragment, not a whole chunk. Screen / webcam / mic / system audio land as SEPARATE tracks, never premixed.

## Prerequisites

- Capability tiers (not yet specced) — a probe that determines whether the hardware encoder can sustain the requested resolution + fps without dropping frames.
- Diagnostics (not yet specced) — surfaces probe results + live record stats.
- Sandbox entitlements added at signing time when this phase starts: `com.apple.security.device.audio-input`, `com.apple.security.device.camera`. `Info.plist` carries the usage strings `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, and `NSScreenCaptureUsageDescription` so the OS can show the consent prompt at first use. Entitlements + Info.plist keys must be present in the signed binary BEFORE the user opens the recorder — the runtime prompt only fires after the binary is properly signed; "request when the recorder opens" was wrong shorthand for "the runtime PROMPT fires when the recorder opens".

## Approach

1. **Source acquisition.**
   - **Display / window / app:** ScreenCaptureKit `SCStream` with `SCStreamConfiguration` (resolution, fps, audio yes/no).
   - **Webcam:** `AVCaptureDevice.discoverySession(deviceTypes: [.builtInWideAngleCamera, .external])` + `AVCaptureSession` + `AVCaptureVideoDataOutput`.
   - **Microphone:** `AVCaptureDevice` + `AVCaptureAudioDataOutput`.
   - **System audio:** `SCStreamConfiguration.capturesAudio = true` on macOS 13+; system audio is delivered as its own audio sample buffer stream on the `SCStream` and routed as a separate track.
2. **Encode-while-record.** Each source feeds an `AVAssetWriter` configured with VideoToolbox `kVTCompressionPropertyKey_RealTime = true` and a target bitrate selected from the capability probe. Hardware encoder sessions are gated by the probe — exceeding the budget yields an explicit error before record starts.
3. **Continuous fragmented MP4 per source + NDJSON event log.** Each writer produces ONE continuous fragmented `.mov` for the whole session with `AVAssetWriter.movieFragmentInterval` set (default 2 s) so the on-disk file is readable up to the last flushed fragment at any moment — including after a power loss or app kill. We do NOT close-and-reopen the writer mid-session: tearing down the encoder at 30 s intervals would risk frame drops and audio glitches at the boundary, and `movieFragmentInterval` already gives crash safety without it. Session metadata is an **append-only NDJSON event log** (`manifest.ndjson`) — one JSON object per line, so a process kill can never corrupt a partially-written record. Record kinds: `header` (source IDs, file paths, encoder configs, `sessionStartHostTime` for epoch math), `epoch` (the wall-clock anchor we subtract from captured PTS), `source-ended`, and a `finalize` marker on clean shutdown. Phase 45 extends this format with a `scene-switch` record kind; unknown record kinds are skipped on read.
4. **PTS normalisation.** Each writer captures with the shared `CMClockGetHostTimeClock()` — those PTS are nanoseconds since boot, NOT project-relative time. At session start we snapshot the host clock as `sessionStartHostTime` and write it into the NDJSON header. On stop, clips land on the timeline at `(capturedPTS − sessionStartHostTime)` so the result starts at zero on the project timeline; inter-track alignment is preserved exactly because every writer uses the same clock and the same offset.
5. **Storage.** Sessions write into `~/Movies/LocalCut Recordings/<session-uuid>/`. The user picks this root folder once via `NSOpenPanel` on the first recording; we create a security-scoped bookmark from the returned URL, persist it in app settings, and on every launch resolve + `startAccessingSecurityScopedResource()` BEFORE the recovery scan can enumerate the folder. Without the bookmark, sandbox blocks both writing new sessions AND reading recovered ones, so the bookmark is part of the recovery contract. Preflight checks `URLResourceKey.volumeAvailableCapacityForImportantUsage`. A live monitor warns at 10% remaining and stops gracefully at 5%.
6. **Track alignment.** All writers share `CMClockGetHostTimeClock()` so captured timestamps are mutually aligned within one audio quantum (≈ 21 µs at 48 kHz). The per-source PTS deltas (after subtracting `sessionStartHostTime` per step 4) preserve that alignment on the project timeline.
7. **Recovery.** On launch, scan `~/Movies/LocalCut Recordings/` for sessions whose `manifest.ndjson` ends without a `finalize` record. Offer them in the media bin as "Recovered session — N s recovered".
8. **Capability matrix.** ScreenCaptureKit system audio requires macOS 13+ on Apple Silicon; Intel Macs are limited. The capability probe in P26 (not yet specced) decides what to enable per host. Recording overall is an accelerated-tier feature in v1.

## Trade-offs

- ScreenCaptureKit (post-macOS 12.3) over legacy `CGDisplayStream`: better app / window targeting, lower CPU, system-audio support.
- Fragmented `.mov` over `.mkv`: AVFoundation writes and reads `.mov` natively; `.mkv` would need an external library.
- One continuous fragmented file per source over chunked rotation: `movieFragmentInterval` flushes a fragment every N seconds (default 2 s), so the on-disk file is already crash-safe up to the last flush. Rotation by close-and-reopen would risk drops at every boundary for no extra safety benefit.

## Risks

- ScreenCaptureKit consent UX shows the OS picker — we cannot pre-pick. UX must explain why a click is required.
- Sustained 4K60 capture can saturate the hardware encoder on baseline tier; the probe must be conservative.

## Non-goals

- Scene mixing (Phase 45).
- Live streaming out (Phase 47).
- Replay buffer (Phase 46).
- Cursor effects (Phase 43).
- Pause / resume UX polish (Phase 42).
