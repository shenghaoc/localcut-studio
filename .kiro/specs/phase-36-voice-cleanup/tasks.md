# Tasks: Phase 36 — Voice Cleanup

> Status: **Complete**. This branch implements persistent voice-cleanup
> settings, UI, live processed preview audio, EBU R128 measurement, and
> writer-path export processing.
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
- [x] **T1.6a** Ensure loudness gain is applied exactly once: loudness-only
  compositions carry gain in `AVAudioMix`, DSP-active compositions leave it to
  `VoiceCleanupDSP`, and loudness measurement builds exclude already-applied
  gain.
- [x] **T1.6b** Rebuild when an active loudness gain value changes and reset
  stale scheduled audio/mixer gain when preview switches between DSP-active,
  loudness-only, and dry routes.
- [x] **T1.7** Route live preview audio through the master bus with the cleanup
  processing chain (denoise → gate → compressor → limiter). The live path
  decodes off the main actor, processes bounded buffers through
  `VoiceCleanupDSP`, schedules them into the bus player node, and mutes the dry
  `AVPlayerItem` audio while cleanup is active.
- [x] **T1.8** Route live preview audio through `AudioMasterBus` so preview and
  offline export share the same `BuiltComposition`, `AVAudioMix`, and cleanup
  DSP implementation.
- [x] **T1.9** Implement volume-ramped live bypass switching for each insert
  with ~5 ms ramp transitions to avoid clicks.

## UI

- [x] **T2.1** Extend the Audio inspector with a Voice Cleanup disclosure:
  ordered insert list, bypass toggles, denoiser/gate/compressor/limiter
  parameters, loudness target/gain controls, and Measure Now.
- [x] **T2.2** Route slider edits through coalesced undo and toggles/presets
  through discrete undoable mutations.
- [x] **T2.3** Add richer live/output meters for per-insert gain reduction once
  live bus routing exists.

## Verification

- [x] **T3.1** LocalCutCore tests cover defaults/no-op behavior, limiter
  clamping, short-range loudness skip, and EBU R128 gain math.
- [x] **T3.2** App tests cover voice-cleanup undo and project-document
  round-trip.
- [x] **T3.3** `swift test --package-path Packages/LocalCutCore` green.
- [x] **T3.4** `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme
  "LocalCut Studio" -destination "platform=macOS"` green.
- [x] **T3.5** Latency-budget test for the live cleanup DSP processing budget.
- [x] **T3.6** Export smoke fixture: noisy clip → denoiser + R128 target →
  actual queued export → measured LUFS within ±0.5 LU.
- [x] **T3.7** App regression proves an active loudness gain-value change
  invalidates composition-derived state.
