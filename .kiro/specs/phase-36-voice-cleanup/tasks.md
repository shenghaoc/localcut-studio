# Tasks: Phase 36 — Voice Cleanup

> Status: **In progress**. This branch implements the model/UI/export-path
> foundation and keeps the remaining live custom-AU parity work explicit.
> Depends on audio master bus.

## Engine

- [x] **T1.1** Add persistent `VoiceCleanupSettings` with ordered inserts:
  denoiser → gate → compressor → limiter, each with bypass and clamped
  parameters.
- [x] **T1.2** Add Accelerate-backed, deterministic DSP helpers for denoiser,
  gate, compressor, limiter, and EBU R128 integrated loudness measurement.
- [x] **T1.3** Persist voice-cleanup settings in `AudioBusDoc`; legacy
  documents decode to bypassed defaults.
- [x] **T1.4** Carry cleanup settings through `BuiltComposition` and force the
  `AVAssetWriter` PCM path when active cleanup requires sample processing.
- [x] **T1.5** Process decoded Int16 PCM audio samples in the writer path before
  append/meter publication, with queue-local state for gate/compressor gain.
- [x] **T1.6** Add current-project loudness measurement and apply the computed
  static makeup gain through undoable project mutation.
- [ ] **T1.7** Replace the current deterministic denoise helper with the final
  custom vDSP spectral-subtraction `AVAudioUnit` mounted on the master bus.
- [ ] **T1.8** Route live preview audio through the master bus so live monitor
  and offline export share the same cleanup node graph.
- [ ] **T1.9** Implement volume-ramped live bypass switching for each insert.

## UI

- [x] **T2.1** Extend the Audio inspector with a Voice Cleanup disclosure:
  ordered insert list, bypass toggles, denoiser/gate/compressor/limiter
  parameters, loudness target/gain controls, Measure Now, and latency budget.
- [x] **T2.2** Route slider edits through coalesced undo and toggles/presets
  through discrete undoable mutations.
- [ ] **T2.3** Add richer live/output meters for per-insert gain reduction once
  live bus routing exists.

## Verification

- [x] **T3.1** LocalCutCore tests cover defaults/no-op behavior, limiter
  clamping, short-range loudness skip, and EBU R128 gain math.
- [x] **T3.2** App tests cover voice-cleanup undo and project-document
  round-trip.
- [x] **T3.3** `swift test --package-path Packages/LocalCutCore` green.
- [x] **T3.4** `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme
  "LocalCut Studio" -destination "platform=macOS"` green.
- [ ] **T3.5** Latency-budget test on the final live custom-AU graph.
- [ ] **T3.6** Export smoke fixture: noisy clip → denoiser + R128 target →
  exported LUFS within ±0.5 LU.
