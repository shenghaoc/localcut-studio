# Tasks: Phase 46 — Replay Buffer and Live Audio Chain

> Status: **Implemented**. Depends on Phase 41 + Phase 36.

## Ring buffer

- [x] **T1.1** `EncodedChunkRing` actor with in-memory chunk list + budget enforcement.
- [x] **T1.2** Keyframe-aligned eviction.
- [x] **T1.3** Disk spill writer/reader under `Caches/ReplayBuffer/<uuid>/`.
- [x] **T1.4** Unified index that bridges memory + spill.
- [x] **T1.5** Disable and release an enabled replay manager when capture startup fails, then clear its ring asynchronously.

## Save command

- [x] **T2.1** "Save last N seconds" command: locate keyframe, finalise fragmented `.mov`, drop clip(s) at playhead.
- [x] **T2.2** Continuation logic: encoder stream never stopped.
- [x] **T2.3** Multi-source replay saves preserve separate video/audio sources on aligned timeline tracks.

## Live audio chain

- [x] **T3.1** Wire Phase 36 inserts on both record and monitor taps.
- [x] **T3.2** Round-trip latency measurement at session start.

## Diagnostics

- [x] **T4.1** Latency + ring memory + spill size in the diagnostics panel.

## Verification

- [x] **T5.1** Mocked-chunk bound test.
- [x] **T5.2** Frame-accuracy test on the inserted clip.
- [x] **T5.3** Latency budget test.
- [x] **T5.4** `xcodebuild` (Debug, macOS) green.
- [x] **T5.5** Focused regression for replay-manager cleanup after capture startup failure.
