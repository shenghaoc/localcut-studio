# Tasks: Phase 36 — Voice Cleanup

> Status: **Proposed**. Depends on audio master bus.

## Engine

- [ ] **T1.1** Build the master bus `AVAudioEngine` graph; route player and export through it.
- [ ] **T1.2** Insert Apple noise-suppression AU on macOS 26+; feature-detect and fall back to RNNoise wrapper.
- [ ] **T1.3** Implement gate, compressor, limiter as `AUAudioUnit` instances or custom render blocks; bypass-ramped switching.
- [ ] **T1.4** Implement EBU R128 integrated-loudness measurement (K-weighted IIR + 400 ms gated blocks) via vDSP.
- [ ] **T1.5** Loudness gain stage on the bus applies a single dB delta per the measurement.

## UI

- [ ] **T2.1** Inspector "Audio" panel: bus insert list, per-insert parameters, bypass toggles, meters.
- [ ] **T2.2** Loudness preset picker + custom field; "measure now" button to run the offline pass.

## Verification

- [ ] **T3.1** Unit tests on R128 vs BS.1770 test vectors.
- [ ] **T3.2** Latency-budget measurement test on the live graph.
- [ ] **T3.3** Smoke: noisy clip → denoise + R128 → export → measured LUFS within ±0.5.
- [ ] **T3.4** `xcodebuild` (Debug, macOS) green.
