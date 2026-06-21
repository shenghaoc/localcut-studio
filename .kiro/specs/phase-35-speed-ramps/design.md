# Design: Phase 35 — Time Remapping (speed ramps + pitch-preserving time-stretch)

> Status: **Proposed**. Target tag: **v0.1.4**.

## Goal

Per-clip keyframed speed curves (0.25× – 4×) with a bezier curve editor, video and audio scheduled correctly through one render path. Audio uses pitch-preserving time-stretch via `AVAudioMix.audioTimePitchAlgorithm`. Frame interpolation for ultra-smooth slow motion is deferred to Phase 37 (Core AI). Cache invalidation rules for render cache when a ramp changes.

## Prerequisites

- Keyframes (not yet specced) — `Keyframe<T>` with bezier handles and an evaluator.
- Render cache (not yet specced) — for invalidating cached frames on ramp edits.
- Audio master bus (not yet specced) — so stretched audio still feeds meters / R128 in Phase 36.

## Approach

1. **Speed curve.** Per-clip `[Keyframe<Float>]` of speed in `[0.25, 4.0]`. Time mapping: integrate the speed curve to get output-time → source-time. We store both the speed curve (authoring) and a sequence of per-track `AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)` calls that approximate it segment-by-segment (a piecewise-constant-speed approximation between keyframes — applied per-track because composition-wide scaling would warp every track uniformly, not just the ramped clip).
2. **Video pipeline.** Split the clip at every keyframe into segments. For each segment compute the source duration / output duration ratio; insert each segment into the composition's video track with `AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)` to produce the target output duration. Continuous easing curves between keyframes are approximated by N sub-segments (default N=10 per keyframe pair; tunable based on perceived smoothness vs. instruction count cost).
3. **Audio pipeline.** Mirror the same segment plan on the audio track. Apply `AVMutableAudioMix` with `audioTimePitchAlgorithm = .timeDomain` (default; lowest-latency WSOLA-class) or `.spectral` (phase-vocoder, better on tonal content) — chosen per-clip with `.timeDomain` as the default. A "preserve pitch" toggle controls whether the pitch algorithm is applied at all; off = pitch slides with speed (chipmunk effect on purpose).
4. **Inspector.** Bezier curve editor: x-axis = output time, y-axis = speed. Standard handle drag with shift-snap and right-click reset. A read-only output-duration field updates live.
5. **Cache invalidation.** When a ramp changes, invalidate render-cache entries for the affected clip's output time range. Audio stretch is computed by AVFoundation at playback / export time and doesn't need a separate cache — but the WSOLA window length determines the latency budget surfaced in diagnostics.
6. **Export parity.** Both `AVPlayerItem` and `AVAssetExportSession` consume the same composition + audio mix; preview and export remain pixel- and sample-aligned.
7. **Reverse playback.** Out of scope for v1 — we document it as deferred because `AVMutableComposition` cannot reverse-scale a time range and a custom reader path is a large diversion. Phase 37's interpolation engine will offer a different reverse path.

## Trade-offs

- `AVAudioTimePitchAlgorithm.timeDomain` (WSOLA) vs `.spectral` (phase vocoder): the former is lower-latency and sounds great on speech / percussion; the latter handles tonal content better. We expose both rather than picking blindly.
- Piecewise-constant approximation of a smooth bezier: simple, robust through AVFoundation, perceptually fine at 10+ subsegments per keyframe pair.
- No custom video reader: keeps us on the standard playback path.

## Risks

- VFR sources: AVFoundation handles VFR through its asset reader but ramp boundaries can land at sub-frame positions on VFR sources; we snap segment boundaries to the source's nearest sample time and document a ±1 frame tolerance.
- Audio drift on very long clips when stretch ratio is far from 1.0; mitigate by re-anchoring at every keyframe boundary.

## Non-goals

- Optical-flow frame interpolation (Phase 37).
- Pitch-shifting as a creative audio effect.
- Reverse playback in v1.
