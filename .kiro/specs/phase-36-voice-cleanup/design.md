# Design: Phase 36 — Voice Cleanup

> Status: **In progress**. Target tag: **v0.1.5**.

## Implementation status

Current branch implements the model, inspector, document persistence, EBU R128
measurement, AVAssetWriter PCM export-path processing, and live preview routing
through the cleanup chain. The live engine routes audio through the same
`VoiceCleanupDSP` code path as offline export, ensuring sample parity.

**Completed tasks:**
- T1.1-T1.6: Settings, DSP, persistence, export path, loudness measurement
- T1.7: Live preview cleanup chain using VoiceCleanupDSP
- T1.8: Live preview routing through AudioMasterBus
- T1.9: Volume-ramped bypass switching (~5 ms transitions)
- T2.1-T2.3: Inspector UI with gain reduction meters
- T3.1-T3.6: Tests including latency budget and export smoke fixture

**Remaining tasks:**
- T1.7 (original): Custom vDSP spectral-subtraction AVAudioUnit (replaced with
  tap-based processing that uses the same DSP code path)

## Goal

Three audio cleanup tools usable both live during monitoring and offline at render time, mounted on the master bus: (a) a noise gate + denoiser, (b) EBU R128 integrated-loudness normalisation, (c) gate + limiter as bus inserts. Bus-insert architecture must match preview and export.

## Prerequisites

- Audio master bus (not yet specced) — an `AVAudioEngine`-backed bus that both the player and the export pipeline route through, with meters at the tap.

## Approach

1. **Denoiser.** `AVAudioInputNode.setVoiceProcessingEnabled(true)` is intentionally NOT used here — it's an input-side IO-unit feature that only processes incoming microphone audio, not pre-recorded clip playback flowing through the master bus. Phase 36's denoise is mounted on the master bus and must therefore work on arbitrary audio routed through the bus (timeline clip playback + live mic monitor + system audio). We ship one vDSP-implemented spectral-subtraction denoiser as an `AVAudioUnit` subclass — same DSP code path runs in real-time rendering AND in `manualRenderingMode = .offline`, so live preview and offline export are sample-identical. Voice processing on the input node is a Phase 41 concern (denoising mic input BEFORE the capture encoder), separate from this phase.
2. **Bus architecture.** One graph drives both live monitor and offline export — `playerNodes` → `AVAudioUnitEQ` (passthrough by default) → custom denoise unit → gate node → compressor node → limiter node → meter tap → `mainMixerNode`. Switching between live (real-time render against output device) and offline (`manualRenderingMode = .offline` rendering to a buffer for export) leaves the chain unchanged — no parallel graphs, no node-swap. Sample parity between preview and export is documented as a verification target.
3. **Loudness normalisation.** EBU R128 integrated-loudness measurement is an offline pass over the export track. We compute LUFS via the standard K-weighted filter + 400 ms gated blocks (`vDSP` for the IIR filtering). The normalisation gain stage on the master bus applies a single dB delta to hit the target.
4. **Targets.** Preset list: –14 LUFS (YouTube / general), –16 LUFS (Apple / Podcasts), –19 LUFS (broadcast), and a custom field. The chosen preset feeds Phase 39 (vertical finishing) per-platform export profiles.
5. **Latency budget.** Document the live-monitor latency contribution per node in `design.md`. Apple's noise suppression AU is ~10 ms; our gate + compressor + limiter target ≤5 ms combined. Total live-monitor latency budget: ≤25 ms (the `bufferSize` and lookahead are bounded accordingly).
6. **A / B bypass.** Each node has a bypass toggle with no glitch on toggle (use `AVAudioMixerNode.outputVolume` ramps).

## Trade-offs

- Custom vDSP denoiser reduces our dependency surface to zero — no third-party static library, no Apple voice-processing AU that doesn't run offline — at the cost of owning the algorithm and its maintenance. Spectral subtraction is a well-understood DSP recipe with no known patent encumbrances.
- Offline R128 vs realtime LRA (loudness range): we ship the integrated measurement only; LRA is a v2 feature.
- Limiter as a true-peak limiter requires 4× oversampling — we expose the option but default to sample-peak with a small margin to keep latency low.

## Risks

- Spectral subtraction handles stationary noise (hum, hiss, fan) cleanly but performs poorly on non-stationary noise (keyboard clicks, door slams) and can introduce musical-noise artefacts; we document this in the user-facing copy and tune the over-subtraction factor conservatively rather than pretend the algorithm is a magic bullet.
- R128 measurement on very short clips (<3 s) is meaningless — the UI states this when range is too short.

## Non-goals

- ML speech enhancement beyond noise suppression.
- Source separation (stems / vocals).
- De-reverb.
