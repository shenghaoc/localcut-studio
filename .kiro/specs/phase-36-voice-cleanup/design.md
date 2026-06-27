# Design: Phase 36 — Voice Cleanup

> Status: **Complete**. Target tag: **v0.1.5**.

## Implementation status

Current branch implements the model, inspector, document persistence, EBU R128
measurement, AVAssetWriter PCM export-path processing, and live preview routing
through the cleanup chain. The live engine decodes composition audio off the
main actor, processes bounded buffers through the same `VoiceCleanupDSP` code
path as offline export, schedules the processed buffers into the master-bus
player node, and mutes the dry `AVPlayerItem` audio while cleanup is active.

**Completed tasks:**
- T1.1-T1.6: Settings, DSP, persistence, export path, loudness measurement
- T1.7: Live preview cleanup chain using VoiceCleanupDSP before scheduling
  bounded buffers into AudioMasterBus
- T1.8: Live preview routing through AudioMasterBus with the dry AVPlayer audio
  path muted while cleanup is active
- T1.9: Volume-ramped bypass switching (~5 ms transitions)
- T2.1-T2.3: Inspector UI with gain reduction meters
- T3.1-T3.6: Tests including latency budget and export smoke fixture

**Implementation note:** The original T1.7 design called for a custom
`AVAudioUnit` subclass. This branch ships the same parity goal with a bounded
processed-buffer path: `AVAssetReader` decodes the current `BuiltComposition`
off the main actor, `VoiceCleanupDSP.processInterleaved` applies the inserts
before scheduling, and the `AVPlayerItem` audio mix is muted so preview does
not double the dry and processed paths.

## Goal

Three audio cleanup tools usable both live during monitoring and offline at render time, mounted on the master bus: (a) a noise gate + denoiser, (b) EBU R128 integrated-loudness normalisation, (c) gate + limiter as bus inserts. Bus-insert architecture must match preview and export.

## Prerequisites

- Audio master bus — an `AVAudioEngine`-backed bus with live/offline metering
  and a live preview player node for processed cleanup buffers.

## Approach

1. **Denoiser.** `AVAudioInputNode.setVoiceProcessingEnabled(true)` is intentionally NOT used here — it's an input-side IO-unit feature that only processes incoming microphone audio, not pre-recorded clip playback. Phase 36's denoise works on arbitrary timeline audio through `VoiceCleanupDSP`, shared by live preview and export. Voice processing on the input node is a Phase 41 concern (denoising mic input BEFORE the capture encoder), separate from this phase.
2. **Bus architecture.** Preview and export share the same `BuiltComposition`, `AVAudioMix`, and `VoiceCleanupDSP` insert order. Live preview decodes bounded PCM chunks off the main actor, applies the DSP chain before scheduling them into an `AVAudioPlayerNode`, and mutes the `AVPlayerItem` audio while cleanup is active. Export uses the `AVAssetWriter` PCM path and the same DSP call. This avoids an observation-tap processor and avoids enqueueing the whole timeline.
3. **Loudness normalisation.** EBU R128 integrated-loudness measurement is an offline pass over the export track. We compute LUFS via the standard K-weighted filter + 400 ms gated blocks (`vDSP` for the IIR filtering). The normalisation gain stage on the master bus applies a single dB delta to hit the target.
4. **Targets.** Preset list: –14 LUFS (YouTube / general), –16 LUFS (Apple / Podcasts), –19 LUFS (broadcast), and a custom field. The chosen preset feeds Phase 39 (vertical finishing) per-platform export profiles.
5. **Latency budget.** Live cleanup schedules at most a bounded lookahead of processed audio and keeps per-buffer DSP processing under the ≤25 ms budget tested at 48 kHz.
6. **A / B bypass.** Each insert has a bypass toggle with a ~5 ms ramp in the live DSP path to avoid clicks.

## Trade-offs

- Custom vDSP denoiser reduces our dependency surface to zero — no third-party static library, no Apple voice-processing AU that doesn't run offline — at the cost of owning the algorithm and its maintenance. Spectral subtraction is a well-understood DSP recipe with no known patent encumbrances.
- Offline R128 vs realtime LRA (loudness range): we ship the integrated measurement only; LRA is a v2 feature.
- Limiter as a true-peak limiter requires 4× oversampling — this phase ships a sample-peak limiter with release smoothing and a small margin to keep latency low.

## Risks

- Spectral subtraction handles stationary noise (hum, hiss, fan) cleanly but performs poorly on non-stationary noise (keyboard clicks, door slams) and can introduce musical-noise artefacts; we document this in the user-facing copy and tune the over-subtraction factor conservatively rather than pretend the algorithm is a magic bullet.
- R128 measurement on very short clips (<3 s) is meaningless — the UI states this when range is too short.

## Non-goals

- ML speech enhancement beyond noise suppression.
- Source separation (stems / vocals).
- De-reverb.
