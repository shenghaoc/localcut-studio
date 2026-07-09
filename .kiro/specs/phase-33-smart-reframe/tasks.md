# Tasks: Phase 33 — Smart Reframe

> Status: **In progress on `next` branch**. Depends on keyframes + Phase 39 aspect modes. Targets macOS 27.

## Engine

- [ ] **T1.1** `actor ReframeAnalyzer` with its own `AVAssetReader`; orchestrates the per-frame pipeline.
- [ ] **T1.2** `VNDetectFaceRectanglesRequest` integration; primary-face selector.
- [ ] **T1.3** `VNGenerateAttentionBasedSaliencyImageRequest` fallback; centroid extractor.
- [ ] **T1.4** `SubjectTracker` — IoU association + One-Euro smoothing.
- [ ] **T1.5** `ShotBoundaryDetector` — chi-squared histogram distance.
- [ ] **T1.6** `KeyframeGenerator` — trajectory → transform keyframes with motion + safe-zone bounds.

## UI

- [ ] **T2.1** Smart Reframe panel: target aspect picker, analyse button, progress, mode indicator.
- [ ] **T2.2** Overlay on `AVPlayerView` for crop + action-safe at the playhead.
- [ ] **T2.3** Apply / Discard / Adjust; transaction-based apply.

## Verification

- [ ] **T3.1** Determinism test on a fixture clip.
- [ ] **T3.2** Motion-bound assertions in unit tests.
- [ ] **T3.3** Safe-zone fixture (16:9 → 9:16) ≥ 95 % compliance.
- [ ] **T3.4** `xcodebuild` (Debug, macOS) green.
