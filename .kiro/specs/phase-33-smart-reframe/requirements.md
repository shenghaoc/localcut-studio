# Requirements: Phase 33 — Smart Reframe

## R1 — Subject detection

- **R1.1** `VNDetectFaceRectanglesRequest` is the primary detector.
- **R1.2** `VNGenerateAttentionBasedSaliencyImageRequest` is the fallback when no faces are detected.
- **R1.3** Mode reported per analysis: `face` | `saliency` | `mixed`.

## R2 — Analysis

- **R2.1** Off-main-actor `actor ReframeAnalyzer` with its own `AVAssetReader`.
- **R2.2** Default sample rate 2 fps; configurable.
- **R2.3** Cancellable; cancel releases in-flight `CVPixelBuffer`s and emits `cancelled`.

## R3 — Tracker

- **R3.1** IoU association across frames (threshold 0.3); single-subject.
- **R3.2** One-Euro filter on tracked centroid (`minCutoff = 1.0`, `beta = 0.007`).
- **R3.3** Tracker resets at shot boundaries.

## R4 — Shot boundaries

- **R4.1** 512-bin RGB histogram (8 bins per channel) per analysis frame.
- **R4.2** Chi-squared distance with threshold 0.5 (configurable in design.md).
- **R4.3** Hold-easing keyframe at `T_cut − ε`; linear-easing keyframe at `T_cut`.

## R5 — Keyframe generation

- **R5.1** Sample interval default 0.5 s.
- **R5.2** Scale ≥ 1.0; only zooms in beyond the aspect fill crop; never introduces letterbox.
- **R5.3** Bounded velocity (0.3 norm/s) and acceleration (0.5 norm/s²) — iterative clamp until convergence.
- **R5.4** Safe-zone compliance ≥ 95 % of frames inside action-safe (centre ± 0.45); **increase** scale by 1 % up to 20 % iteratively until met (more overscan → more pan headroom). Never reduce below 1.0 (that would reveal letterbox). If still unmet after the 20 % cap, surface the limitation in the UI rather than violate the no-letterbox invariant.

## R6 — Review-before-apply

- **R6.1** Overlay on `AVPlayerView` draws the target-aspect crop + action-safe inner rect at the playhead.
- **R6.2** Apply / Discard / Adjust controls; Adjust exposes velocity, acceleration, analysis fps.
- **R6.3** Apply replaces the clip's transform keyframes in a single undoable transaction.
- **R6.4** Generated keyframes are user-editable post-apply; they are standard Phase 15 entries.

## R7 — Verification

- **R7.1** Deterministic keyframe output on fixture clips at fixed analysis parameters.
- **R7.2** Motion-bound assertions hold (velocity / acceleration).
- **R7.3** 16:9 → 9:16 fixture: subject inside safe zone ≥ 95 % of frames.
- **R7.4** `xcodebuild` (Debug, macOS) green; no test count regression.
