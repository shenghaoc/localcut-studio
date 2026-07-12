# Design: Phase 46 — Replay Buffer and Live Audio Chain

> Status: **Implemented**. Target tag: **v0.1.13**.

## Goal

(a) A keyframe-aligned ring buffer of encoded chunks (RAM with disk spill, configurable duration). "Save last N seconds" finalises the buffered keyframe-aligned span into a clip dropped onto the timeline while recording continues uninterrupted. (b) Live inserts on the monitor path in `AVAudioEngine` — gate, compressor, limiter, and the Phase 36 denoiser — reusing existing meters, with the added latency surfaced.

The browser-editor's v1 runs DSP in the worker's capture loop (not an `AudioWorklet`) for deterministic delivery to the encoder. The native port keeps the same recipe: live audio inserts run on the `AVAudioEngine` graph that already carries the monitor + writer, not on a separate thread.

## Prerequisites

- Phase 41 capture engine — the ring buffer taps the **encoded output** of the Phase 41 writer (after VideoToolbox produces `CMSampleBuffer`s with keyframe attachments). Pre-encoder raw frames have no keyframe boundaries and at 4K30 a 256 MiB budget would cover only a couple of seconds; only the encoded-chunk tap gets the advertised 30 s – 300 s durations. Saves finalise the buffered encoded chunks into a fragmented `.mov` without re-encoding.
- Phase 36 voice cleanup — provides the denoiser, gate, limiter, compressor inserts.
- Audio master bus + meters (shared with Phase 36).

## Approach

1. **Ring buffer structure.** Encoded `CMSampleBuffer` chunks (or `EncodedVideoChunk`-equivalent) held in memory up to a 256 MiB default budget, with a configurable duration cap (e.g. 30 s, 60 s, 300 s). Each chunk records its `decodeTimeStamp`, `presentationTimeStamp`, byte size, and whether it is a keyframe.
2. **Keyframe alignment.** A "save last N seconds" command locates the **latest keyframe at or before** `now − N` and finalises from there — so the saved span is always ≥ N seconds and starts on a decodable boundary. (Picking the earliest keyframe `≥ now − N` would start AFTER the requested boundary and silently shorten the clip.) Eviction respects keyframe boundaries: an older keyframe segment is evicted as a whole unit, never partially. When the buffer's oldest keyframe is itself younger than `now − N` (a short ring or a recent session start), the save returns whatever is available with the actual span surfaced in the UI.
3. **Disk spill (ring-buffer overflow to `Caches/`).** When the in-memory budget would be exceeded, oldest keyframe-aligned spans spill to `<app-container>/Library/Caches/ReplayBuffer/<session-uuid>/` — the app sandbox gives unrestricted read / write access to its own Caches directory via `FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)`, so no security-scoped bookmark or user-selected folder is needed. Each spill file is a timestamped binary record; the in-memory index keeps pointers. Saves reading from spilled chunks just `fread` them.
4. **Save command.** Finalises fragmented `.mov` segment(s) from the buffered chunks (in-memory + spilled, in order). When a replay span includes multiple capture source files, each source is finalised separately and inserted as its own media item so screen, webcam, system audio, and microphone sources remain independently editable. The editor inserts the batch at the playhead as one undo step, preserving relative source offsets and placing overlapping sources on distinct video/audio tracks. Recording continues without interruption (single encoder session, never stopped).
5. **Live audio chain.** Phase 36's master-bus inserts (denoiser, gate, compressor, limiter) sit between mic / system-audio capture and the encoder feed. The same `AVAudioEngine` graph drives the monitor tap so what the user hears matches what gets recorded.
6. **Latency measurement.** A round-trip measurement at session start (input → graph → output) reports total live-monitor latency. Surfaced in the diagnostics panel and the recorder UX.
7. **Recovery.** If the app crashes, the ring buffer's in-memory portion is lost; spilled chunks remain. On next launch Phase 41 recovery offers the session whose chunks include both the (recoverable) main encoded stream and any spilled ring entries — the user can choose to import either.
8. **Failure cleanup.** Replay setup finishes before capture startup so the encoded-chunk callback can capture the manager. If capture startup then fails, `EditorModel` synchronously clears its manager reference and disables appends before restoring recorder UI state. Ring clearing is scheduled in an unstructured task and executes on the `EncodedChunkRing` actor, so spill-file removal cannot delay the main-actor failure transition.

## Trade-offs

- Worker-loop DSP (matching the browser-editor) over a separate `AudioWorklet` thread: deterministic encoder delivery beats marginal CPU isolation gains, and the AU `noise-suppression` we use for denoise (Phase 36) is already a fixed-latency processor.
- 256 MiB default budget covers ~3 minutes of 1080p30 H.264 at typical bitrate; configurable for memory-constrained hosts.
- Keyframe-aligned saves can be slightly longer than the requested duration (saved span ≥ N) but never start mid-GOP.

## Risks

- Spill IO under the App Sandbox: `Library/Caches/ReplayBuffer/` is inside the app container, so reading + writing don't need a security-scoped bookmark. This intentionally does NOT reuse Phase 41's recordings folder — that path is user-selected and may not be accessible without resolving its bookmark first; the cache path is always available.
- A user repeatedly hitting "save last N seconds" finalises clips into the app-container Caches partition (the saved fragmented `.mov` becomes a timeline source under `Library/Caches/ReplayBuffer/`) and can accumulate disk usage; we offer a per-session retention setting and surface the running footprint in diagnostics. (Saved clips are NOT written to `~/Movies` — that's Phase 41's recordings location, not Phase 46's path.)

## Non-goals

- ShadowPlay-style OS-wide background capture (browser / sandbox sessions only).
- Automatic save scheduling.
