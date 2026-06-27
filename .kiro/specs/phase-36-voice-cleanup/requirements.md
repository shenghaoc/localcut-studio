# Requirements: Phase 36 — Voice Cleanup

## R1 — Master bus inserts

- **R1.1** Master bus exposes ordered inserts: denoiser → gate → compressor → limiter, each with bypass.
- **R1.2** One `VoiceCleanupDSP` implementation is used by both preview and export. Live preview decodes composition audio off the main actor, processes bounded buffers through `VoiceCleanupDSP`, schedules them into the master-bus `AVAudioPlayerNode`, and mutes the dry `AVPlayerItem` audio while cleanup is active. Offline export uses the same DSP in the `AVAssetWriter` PCM path. `AVAudioInputNode.setVoiceProcessingEnabled` is explicitly NOT used here — that's input-side mic denoise, which is Phase 41's concern.
- **R1.3** Bypass toggles introduce no audible glitch (volume-ramped switching).

## R2 — Denoiser

- **R2.1** The vDSP spectral-subtraction denoiser in `VoiceCleanupDSP` is the only denoise implementation — no Apple voice-processing AU and no RNNoise fallback.
- **R2.2** Live decoding and DSP stay off the main actor and use bounded scheduling so long timelines do not enqueue the full remaining composition into memory.
- **R2.3** Live-monitor end-to-end latency stays within the documented budget (≤25 ms total bus).

## R3 — Loudness normalisation

- **R3.1** Offline EBU R128 integrated-loudness measurement on the export render pass.
- **R3.2** Targets: presets for –14, –16, –19 LUFS plus a custom field; persisted with the project.
- **R3.3** Applied loudness lands within ±0.5 LU of the target on fixtures longer than 30 s.
- **R3.4** Ranges shorter than 3 s skip normalisation and surface a user-visible note.

## R4 — Gate + compressor + limiter

- **R4.1** Gate: threshold, attack, release, range (downward expander recipe).
- **R4.2** Compressor: threshold, ratio, attack, release, makeup gain.
- **R4.3** Limiter: ceiling (default –1 dBTP equivalent at sample peak with a margin), release.
- **R4.4** All parameters persist with the project and survive bundle round-trip.

## R5 — Verification

- **R5.1** Unit tests cover the R128 calculation against an absolute reference-style 1 kHz tone.
- **R5.2** Latency-budget test: cleanup DSP processing stays within the documented live scheduling budget.
- **R5.3** Smoke: clip with noise → enable denoiser + R128 to –14 → export → measured LUFS within ±0.5.
- **R5.4** `xcodebuild` green; no test count regression.
