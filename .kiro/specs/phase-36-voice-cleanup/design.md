# Design: Phase 36 — Voice Cleanup

> Status: **Proposed**. Target tag: **v0.1.5**.

## Goal

Three audio cleanup tools usable both live during monitoring and offline at render time, mounted on the master bus: (a) a noise gate + denoiser, (b) EBU R128 integrated-loudness normalisation, (c) gate + limiter as bus inserts. Bus-insert architecture must match preview and export.

## Prerequisites

- Audio master bus (not yet specced) — an `AVAudioEngine`-backed bus that both the player and the export pipeline route through, with meters at the tap.

## Approach

1. **Denoiser.** Apple's voice-processing IO unit (`AVAudioInputNode.setVoiceProcessingEnabled(true)`, available since macOS 10.15) is gated to real-time rendering against an audio device and refuses to run when the engine is in `manualRenderingMode = .offline` (documented in WWDC19 §510). Live monitor and export therefore use DIFFERENT denoiser instances built around the SAME tuning parameters:
   - **Live monitor:** voice-processing-enabled input node on the real-time `AVAudioEngine` — Apple-provided, low-latency, integrated.
   - **Export (offline render):** a vDSP-implemented spectral-subtraction denoiser sharing the same tuning surface, plus a small set of golden-frame tests asserting parity with the live AU on test signals (so the user-facing setting "denoise on" sounds the same across both paths within the documented tolerance).
2. **Bus architecture.** Live monitor: `AVAudioEngine` graph — `playerNodes` → `AVAudioUnitEQ` (passthrough by default) → voice-processing-enabled input node → gate node → compressor node → limiter node → meter tap → `mainMixerNode`. Export render: a parallel offline graph swapping the voice-processing input node for the vDSP offline denoiser; the gate / compressor / limiter / meter nodes work in both modes and are reused as-is. The split is the unavoidable consequence of Apple's voice-processing real-time restriction.
3. **Loudness normalisation.** EBU R128 integrated-loudness measurement is an offline pass over the export track. We compute LUFS via the standard K-weighted filter + 400 ms gated blocks (`vDSP` for the IIR filtering). The normalisation gain stage on the master bus applies a single dB delta to hit the target.
4. **Targets.** Preset list: –14 LUFS (YouTube / general), –16 LUFS (Apple / Podcasts), –19 LUFS (broadcast), and a custom field. The chosen preset feeds Phase 39 (vertical finishing) per-platform export profiles.
5. **Latency budget.** Document the live-monitor latency contribution per node in `design.md`. Apple's noise suppression AU is ~10 ms; our gate + compressor + limiter target ≤5 ms combined. Total live-monitor latency budget: ≤25 ms (the `bufferSize` and lookahead are bounded accordingly).
6. **A / B bypass.** Each node has a bypass toggle with no glitch on toggle (use `AVAudioMixerNode.outputVolume` ramps).

## Trade-offs

- Apple's bundled denoiser reduces our dependency surface to zero and integrates with the OS audio session.
- Offline R128 vs realtime LRA (loudness range): we ship the integrated measurement only; LRA is a v2 feature.
- Limiter as a true-peak limiter requires 4× oversampling — we expose the option but default to sample-peak with a small margin to keep latency low.

## Risks

- Apple AU availability across macOS versions; we feature-detect and fall back to RNNoise.
- R128 measurement on very short clips (<3 s) is meaningless — the UI states this when range is too short.

## Non-goals

- ML speech enhancement beyond noise suppression.
- Source separation (stems / vocals).
- De-reverb.
