# Requirements: Phase 36 — Voice Cleanup

## R1 — Master bus inserts

- **R1.1** Master bus exposes ordered inserts: denoiser → gate → compressor → limiter, each with bypass.
- **R1.2** A single custom `AVAudioUnit` (vDSP spectral-subtraction denoiser) is mounted on the master bus; it runs in both real-time rendering and `manualRenderingMode = .offline` so live monitor and offline export use the SAME node graph and produce sample-identical output. `AVAudioInputNode.setVoiceProcessingEnabled` is explicitly NOT used here — that's input-side mic denoise, which is Phase 41's concern.
- **R1.3** Bypass toggles introduce no audible glitch (volume-ramped switching).

## R2 — Denoiser

- **R2.1** Default to the macOS-bundled noise suppression AU when available on the target OS; fall back to RNNoise via a thin static library if not.
- **R2.2** Adds no underruns at the standard 128-sample render quantum on a baseline-tier Mac.
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

- **R5.1** Unit tests on the R128 calculation against a published reference signal (BS.1770 test vectors).
- **R5.2** Latency-budget test: measured input-to-output delay on the live graph under the documented budget.
- **R5.3** Smoke: clip with noise → enable denoiser + R128 to –14 → export → measured LUFS within ±0.5.
- **R5.4** `xcodebuild` green; no test count regression.
