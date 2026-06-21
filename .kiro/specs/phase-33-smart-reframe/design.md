# Design: Phase 33 — Smart Reframe

> Status: **Proposed**. Target tag: **v0.2.3**. Blocked on macOS 27 leaving beta. The Vision-framework face / saliency requests it needs work on macOS 26 today, but we hold this phase until macOS 27 so the ML tier shares one OS baseline.

## Goal

Automatic crop-path generation when converting between aspect ratios (16:9 ↔ 9:16 / 1:1 / 4:5). Detect the primary subject, smooth its trajectory, generate **editable transform keyframes** (Phase 15 model). Reset tracking at shot boundaries. Review-before-apply via a preview overlay.

The browser-editor ships UltraFace RFB-320 ONNX + a pure-DSP saliency fallback + IoU/One-Euro tracker + chi-squared histogram shot detector + bounded keyframe generator. The native port keeps every algorithm choice and swaps the model layer for Apple Vision.

## Prerequisites

- Keyframes (not yet specced) — `[Keyframe<CGAffineTransform>]` on `Clip.transform` with bezier eases.
- Phase 39 aspect modes (target aspects come from there).

## Approach

1. **Detection.** `VNDetectFaceRectanglesRequest` is the default subject detector — built into Vision, no model download, runs on the Neural Engine on Apple Silicon. For faceless footage, `VNGenerateAttentionBasedSaliencyImageRequest` returns a normalised saliency map; centroid of the highest-weighted region is the subject.
2. **Off-main-actor analysis.** An `actor ReframeAnalyzer` owns its own `AVAssetReader` for offline frame scanning at ~2 fps (rate documented + configurable). Mirrors the browser's "dedicated Smart Reframe worker" pattern.
3. **Tracker.** IoU-based association across frames (threshold 0.3) with One-Euro smoothing on the tracked centroid (`minCutoff = 1.0 Hz`, `beta = 0.007`). Single-subject in v1. ~60 lines of Swift; no external dep.
4. **Shot boundaries.** 512-bin RGB histogram per frame (8 bins / channel); chi-squared distance with threshold 0.5; resets the tracker and emits a `hold` keyframe at `T_cut − ε`.
5. **Keyframe generator.**
   - Sample interval default 0.5 s.
   - Scale starts at 1.0 (above the aspect's fill crop); only increases for tighter framing; never below 1.0.
   - Position: `x = -subjectCx * scale`, `y = -subjectCy * scale` (subject in centred coords, negate to shift the layer).
   - Bound velocity (0.3 norm/s) and acceleration (0.5 norm/s²) iteratively until convergence.
   - Safe-zone (action-safe centre ± 0.45): if compliance < 95 %, reduce scale by 1 % up to 20 % until satisfied; never below 1.0; if still unmet, note the limitation in the UI.
6. **Review overlay.** A SwiftUI overlay above `AVPlayerView` draws the target-aspect crop rectangle + a dashed action-safe inner rect at the current playhead, sampling the proposed keyframes via the existing keyframe evaluator. No GPU readback — pure SwiftUI shapes.
7. **Apply.** Replaces the clip's transform keyframe tracks in one undoable transaction. After apply the user can edit, delete, or extend the keyframes by hand.

## Trade-offs

- Apple Vision faces are well-tuned, free, and on-device — no need for UltraFace.
- The browser version's "load face model on user action" gesture is unnecessary on macOS (built-in Vision); we run detection on first use without a model-load step, matching the saliency-on-demand pattern.
- 2 fps analysis cadence with smoothed interpolation between samples balances accuracy with offline time.

## Risks

- VFR sources: the analyser uses the source's actual presentation timestamps; downstream keyframes still snap to project timebase at apply time.
- Very short clips (<0.5 s) get keyframes at start + end only — surfaced in the UI.
- Vision face detection's "primary subject" heuristic is largest-and-most-central; ambiguous cases are documented and reviewable.

## Non-goals

- Multi-subject simultaneous framing.
- Object-class tracking beyond faces / saliency.
- Automatic cutting / reordering.
- Real-time / live reframe.
- Audio analysis.
