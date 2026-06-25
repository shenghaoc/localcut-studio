# Design: Phase 41 — Capture Engine

> Status: **Proposed**. Target tag: **v0.1.8**.

## Goal

Recording as a first-class source. ScreenCaptureKit for display / window / app capture; AVCaptureSession for webcam + microphone; encode-while-recording via VideoToolbox; one continuous **fragmented** `.mov` per source streamed incrementally to disk so a crash loses at most the last un-flushed fragment, not a whole chunk. Screen / webcam / mic / system audio land as SEPARATE tracks, never premixed.

Phase 41 stops at a reliable start / stop / recover / land pipeline. Countdown, pause / resume, retake, floating controls, PiP layouts, and mid-session source switching belong to Phase 42. Scene switching and program output belong to Phase 45.

## Prerequisites

- Capability tiers (implemented in `Packages/LocalCutCore/Sources/LocalCutCore/Capabilities/Capabilities.swift`) provide the host-level gate via `Capabilities.tier(for: .simultaneousCaptureStreams(count:))`. Phase 41 adds the per-source resolution / fps preflight on top; the tier resolver answers "can this Mac run N capture streams at all?", not "can this exact 4K60 setup hold real time?".
- Diagnostics panel (implemented) is the surface for capability reasons and live record stats. Phase 41 should publish recorder-specific counters through the existing diagnostics/status surfaces instead of adding ad-hoc logs.
- App-scope bookmarks are already enabled for sandboxed files. Phase 41 adds a recordings-root bookmark in app settings and resolves it before any recovery scan.
- Sandbox entitlements added at signing time when this phase starts: `com.apple.security.device.audio-input`, `com.apple.security.device.camera`. `Info.plist` carries `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` so the OS can show the consent prompt at first use. Screen recording is handled through the ScreenCaptureKit / TCC flow (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` as the preflight/request bridge) plus user-visible denial guidance. Entitlements + Info.plist keys must be present in the signed binary BEFORE the user opens the recorder — the runtime prompt only fires after the binary is properly signed; "request when the recorder opens" was wrong shorthand for "the runtime PROMPT fires when the recorder opens".

## Approach

1. **Session ownership.** `CaptureCoordinator` is a dedicated actor that owns all capture sources, writer lifetimes, manifest writes, capacity monitoring, and recovery parsing. `EditorModel` stays `@MainActor` and only starts / stops sessions, reflects status, and lands resulting media. Source descriptors and session snapshots are `Sendable` value types so the actor boundary is explicit.
2. **Source acquisition.**
   - **Display / window / app:** ScreenCaptureKit `SCStream` with `SCStreamConfiguration` (resolution, fps, audio yes/no).
   - **Webcam:** `AVCaptureDevice.DiscoverySession` for built-in and external cameras + `AVCaptureSession` + `AVCaptureVideoDataOutput`.
   - **Microphone:** `AVCaptureDevice` + `AVCaptureAudioDataOutput`.
   - **System audio:** `SCStreamConfiguration.capturesAudio = true` on macOS 13+; system audio is delivered as its own audio sample buffer stream on the `SCStream` and routed as a separate track.
3. **Encode-while-record.** Each source feeds an `AVAssetWriter` configured with VideoToolbox `kVTCompressionPropertyKey_RealTime = true` and a target bitrate selected from the capability + source probe. Hardware encoder sessions are gated by `Capabilities.tier(for: .simultaneousCaptureStreams(count:))`; exceeding the budget yields an explicit error before record starts. Each writer input uses bounded buffering: when `isReadyForMoreMediaData` stays false past the configured tolerance, the session records a dropped-frame / backpressure event and surfaces it, rather than accumulating unbounded sample buffers on the actor.
4. **Continuous fragmented `.mov` per source + NDJSON event log.** Each writer produces ONE continuous fragmented `.mov` for the whole session with `AVAssetWriter.movieFragmentInterval` set (default 2 s) so the on-disk file is readable up to the last flushed fragment at any moment — including after a power loss or app kill. We do NOT close-and-reopen the writer mid-session: tearing down the encoder at 30 s intervals would risk frame drops and audio glitches at the boundary, and `movieFragmentInterval` already gives crash safety without it. Session metadata is an **append-only NDJSON event log** (`manifest.ndjson`) — one JSON object per line, so a process kill can only truncate the last line. Readers ignore a partial trailing line and skip unknown `kind` values. Record kinds in Phase 41: `header` (source IDs, file paths, encoder configs, `sessionStartHostTime` for epoch math), `epoch` (the wall-clock anchor we subtract from captured PTS), `source-ended`, `backpressure`, and a `finalize` marker on clean shutdown. Phase 45 extends this format with `scene-doc` / `scene-switch` records.
5. **PTS normalisation.** Each writer captures with the shared `CMClockGetHostTimeClock()` — those PTS are nanoseconds since boot, NOT project-relative time. At session start we snapshot the host clock as `sessionStartHostTime` and write it into the NDJSON header. On stop, clips land on the timeline at `(capturedPTS − sessionStartHostTime)` so the result starts at zero on the project timeline; inter-track alignment is preserved exactly because every writer uses the same clock and the same offset.
6. **Storage.** Sessions write into `~/Movies/LocalCut Recordings/<session-uuid>/`. The user picks this root folder once via `NSOpenPanel` on the first recording; we create a security-scoped bookmark from the returned URL, persist it in app settings, and on every launch resolve + `startAccessingSecurityScopedResource()` BEFORE the recovery scan can enumerate the folder. Without the bookmark, sandbox blocks both writing new sessions AND reading recovered ones, so the bookmark is part of the recovery contract. Preflight checks `URLResourceKey.volumeAvailableCapacityForImportantUsage`. A live monitor warns at 10% remaining and stops gracefully at 5%.
7. **Track alignment.** All writers share `CMClockGetHostTimeClock()` so captured timestamps are mutually aligned within one audio quantum (≈ 21 µs at 48 kHz). The per-source PTS deltas (after subtracting `sessionStartHostTime` per step 5) preserve that alignment on the project timeline.
8. **Landing into the project.** Clean stops and recovered sessions create normal `MediaItem`s backed by the per-source `.mov` files. Landing adds one track per captured source, using the normalized start offset and source duration from the manifest / asset metadata. The landing path is undoable as a single "Add Recording" action and never silently merges screen, camera, mic, or system audio.
9. **Recovery.** On launch, after resolving the recordings-root bookmark, scan `LocalCut Recordings` for sessions whose `manifest.ndjson` ends without a `finalize` record. Offer them in the media bin as "Recovered session — N s recovered". If the root bookmark is stale or missing, recovery becomes a user-visible "Choose recordings folder to recover sessions" state instead of failing silently.
10. **Capability matrix.** ScreenCaptureKit system audio availability is feature-detected per host; Intel Macs are limited. Recording overall is an accelerated-tier feature in v1, while multi-source sessions that require 3+ hardware encoders are pro-tier.

## Trade-offs

- ScreenCaptureKit (post-macOS 12.3) over legacy `CGDisplayStream`: better app / window targeting, lower CPU, system-audio support.
- Fragmented `.mov` over `.mkv`: AVFoundation writes and reads `.mov` natively; `.mkv` would need an external library.
- One continuous fragmented file per source over chunked rotation: `movieFragmentInterval` flushes a fragment every N seconds (default 2 s), so the on-disk file is already crash-safe up to the last flush. Rotation by close-and-reopen would risk drops at every boundary for no extra safety benefit.
- Bounded backpressure over "never drop": a real-time recorder cannot keep infinite buffers when the encoder stalls. Dropping with a manifest event and visible warning is safer than memory growth that takes down the whole session.

## Risks

- ScreenCaptureKit consent UX shows the OS picker — we cannot pre-pick. UX must explain why a click is required.
- Sustained 4K60 capture can saturate the hardware encoder on baseline tier; the probe must be conservative.

## Non-goals

- Scene mixing (Phase 45).
- Live streaming out (Phase 47).
- Replay buffer (Phase 46).
- Cursor effects (Phase 43).
- Pause / resume UX polish (Phase 42).
