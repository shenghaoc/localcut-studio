# Design: Phase 46 — Replay Buffer and Live Audio Chain

> Status: **Proposed**. Target tag: **v0.1.13**.

## Goal

(a) A keyframe-aligned ring buffer of encoded chunks (RAM with disk spill, configurable duration). "Save last N seconds" finalises the buffered keyframe-aligned span into a clip dropped onto the timeline while recording continues uninterrupted. (b) Live inserts on the monitor path in `AVAudioEngine` — gate, compressor, limiter, and the Phase 36 denoiser — reusing existing meters, with the added latency surfaced.

The browser-editor's v1 runs DSP in the worker's capture loop (not an `AudioWorklet`) for deterministic delivery to the encoder. The native port keeps the same recipe: live audio inserts run on the `AVAudioEngine` graph that already carries the monitor + writer, not on a separate thread.

## Prerequisites

- Phase 41 capture engine — the ring buffer sits in front of the encoder; saves finalise into the chunked writer path.
- Phase 36 voice cleanup — provides the denoiser, gate, limiter, compressor inserts.
- Audio master bus + meters (shared with Phase 36).

## Approach

1. **Ring buffer structure.** Encoded `CMSampleBuffer` chunks (or `EncodedVideoChunk`-equivalent) held in memory up to a 256 MiB default budget, with a configurable duration cap (e.g. 30 s, 60 s, 300 s). Each chunk records its `decodeTimeStamp`, `presentationTimeStamp`, byte size, and whether it is a keyframe.
2. **Keyframe alignment.** A "save last N seconds" command locates the **latest keyframe at or before** `now − N` and finalises from there — so the saved span is always ≥ N seconds and starts on a decodable boundary. (Picking the earliest keyframe `≥ now − N` would start AFTER the requested boundary and silently shorten the clip.) Eviction respects keyframe boundaries: an older keyframe segment is evicted as a whole unit, never partially. When the buffer's oldest keyframe is itself younger than `now − N` (a short ring or a recent session start), the save returns whatever is available with the actual span surfaced in the UI.
3. **Disk spill (ring-buffer overflow to `Caches/`).** When the in-memory budget would be exceeded, oldest keyframe-aligned spans spill to `<app-container>/Library/Caches/ReplayBuffer/<session-uuid>/` — the app sandbox gives unrestricted read / write access to its own Caches directory via `FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)`, so no security-scoped bookmark or user-selected folder is needed. Each spill file is a timestamped binary record; the in-memory index keeps pointers. Saves reading from spilled chunks just `fread` them.
4. **Save command.** Finalises a fragmented `.mov` segment from the buffered chunks (in-memory + spilled, in order), wraps it in an `AVURLAsset`, and inserts a new `Clip` on the timeline at the playhead. Recording continues without interruption (single encoder session, never stopped).
5. **Live audio chain.** Phase 36's master-bus inserts (denoiser, gate, compressor, limiter) sit between mic / system-audio capture and the encoder feed. The same `AVAudioEngine` graph drives the monitor tap so what the user hears matches what gets recorded.
6. **Latency measurement.** A round-trip measurement at session start (input → graph → output) reports total live-monitor latency. Surfaced in the diagnostics panel and the recorder UX.
7. **Recovery.** If the app crashes, the ring buffer's in-memory portion is lost; spilled chunks remain. On next launch Phase 41 recovery offers the session whose chunks include both the (recoverable) main encoded stream and any spilled ring entries — the user can choose to import either.

## Trade-offs

- Worker-loop DSP (matching the browser-editor) over a separate `AudioWorklet` thread: deterministic encoder delivery beats marginal CPU isolation gains, and the AU `noise-suppression` we use for denoise (Phase 36) is already a fixed-latency processor.
- 256 MiB default budget covers ~3 minutes of 1080p30 H.264 at typical bitrate; configurable for memory-constrained hosts.
- Keyframe-aligned saves can be slightly longer than the requested duration (saved span ≥ N) but never start mid-GOP.

## Risks

- Spill IO blocked by sandbox: the spill directory must be inside an already-granted user folder (we reuse the Phase 41 recordings directory's parent).
- A user repeatedly hitting "save last N seconds" can fill the user's Movies folder if not pruned; we offer a per-session retention setting and document the disk footprint.

## Non-goals

- ShadowPlay-style OS-wide background capture (browser / sandbox sessions only).
- Multiple simultaneous replay tracks in v1.
- Automatic save scheduling.
