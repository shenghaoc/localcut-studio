# Tasks: Phase 46 — Replay Buffer and Live Audio Chain

> Status: **Proposed**. Depends on Phase 41 + Phase 36.

## Ring buffer

- [ ] **T1.1** `EncodedChunkRing` actor with in-memory chunk list + budget enforcement.
- [ ] **T1.2** Keyframe-aligned eviction.
- [ ] **T1.3** Disk spill writer/reader under `Caches/ReplayBuffer/<uuid>/`.
- [ ] **T1.4** Unified index that bridges memory + spill.

## Save command

- [ ] **T2.1** "Save last N seconds" command: locate keyframe, finalise fragmented `.mov`, drop clip at playhead.
- [ ] **T2.2** Continuation logic: encoder stream never stopped.

## Live audio chain

- [ ] **T3.1** Wire Phase 36 inserts on both record and monitor taps.
- [ ] **T3.2** Round-trip latency measurement at session start.

## Diagnostics

- [ ] **T4.1** Latency + ring memory + spill size in the diagnostics panel.

## Verification

- [ ] **T5.1** Mocked-chunk bound test.
- [ ] **T5.2** Frame-accuracy test on the inserted clip.
- [ ] **T5.3** Latency budget test.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
