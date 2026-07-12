# Requirements: Phase 46 — Replay Buffer and Live Audio Chain

## R1 — Ring buffer

- **R1.1** Keyframe-aligned ring buffer of encoded chunks; configurable duration (default 30 s) and memory budget (default 256 MiB).
- **R1.2** Each chunk records `decodeTimeStamp`, `presentationTimeStamp`, byte size, keyframe flag.
- **R1.3** Eviction respects keyframe boundaries (whole GOP units).

## R2 — Disk spill

- **R2.1** When memory budget would be exceeded, oldest keyframe-aligned GOPs spill to `Caches/ReplayBuffer/<session-uuid>/`.
- **R2.2** Spill files live inside the app container's Caches directory (`FileManager` `.cachesDirectory` in `.userDomainMask`) — full read/write access under the App Sandbox without any user-selected folder or security-scoped bookmark.
- **R2.3** In-memory index covers spilled chunks; saves can read across the boundary.

## R3 — Save command

- **R3.1** "Save last N seconds" finalises a keyframe-aligned span starting from the **latest keyframe at or before** `now − N` (so the saved span is always ≥ N seconds, never silently shortened). When no in-buffer keyframe sits that far back (short ring / recent session start) the save returns whatever IS available, with the actual span surfaced in the UI.
- **R3.2** Result lands at the playhead as timeline clip(s). Multi-source saves preserve simultaneous video/audio sources as separate media items and place overlapping sources on distinct timeline tracks with their relative offsets intact.
- **R3.3** Recording continues uninterrupted; no encoder restart.

## R4 — Live audio chain

- **R4.1** Phase 36 master-bus inserts (denoise, gate, compressor, limiter) operate on the recording path AND the monitor path with identical processing.
- **R4.2** Latency measurement at session start; total live-monitor latency reported in diagnostics.

## R5 — Persistence + recovery

- **R5.1** Ring memory stays within its configured bound (mocked-chunk tests verify).
- **R5.2** Save-last-N-seconds succeeds repeatedly during a continuous session.
- **R5.3** Spilled chunks remain after a crash and are presented to the recovery flow.
- **R5.4** If replay setup succeeds but capture startup fails, the editor immediately disables and releases the replay manager, restores recorder UI state, and clears ring storage asynchronously so cleanup cannot delay the failure transition.

## R6 — Verification

- **R6.1** Mocked-chunk test: 30 saves in a row → memory stays within bound.
- **R6.2** Frame-accuracy test: the inserted clip is sample-aligned with the ongoing recording.
- **R6.3** Latency budget test on the live monitor graph.
- **R6.4** `xcodebuild` (Debug, macOS) green; no test count regression.
- **R6.5** A focused regression verifies failed capture startup clears the editor's replay-manager ownership and disables the manager.
