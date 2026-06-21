# Design: Phase 32b — Landmark-Driven Beauty

> Status: **Proposed**. Target tag: **v0.2.4**. Blocked on macOS 27 leaving beta.

## Goal

Face detection + dense landmarks driving a Metal mesh-warp pass: keyframable jaw slim, eye enlarge, nose width, and mouth, every parameter defaulting subtle, every result deterministic and undoable. Landmarks also upgrade the Phase 32a chroma skin mask to a geometry-aware mask. Strength 0 is a bit-exact identity. v1 follows the primary face (largest / most central); multi-face is a documented design decision.

The browser-editor pipeline runs detection + landmarks via ONNX models on ORT-WebGPU. The native port uses Apple Vision (built into macOS) instead — no model download, no manifest, integrates with the Neural Engine.

## Prerequisites

- Phase 32a (GPU skin smoothing) — landmarks upgrade its skin mask.
- Keyframes (not yet specced) for parameter animation.
- `feature-colour-grading`'s custom `AVVideoCompositing` (the warp pass is an effect node in the chain).

## Approach

1. **Detection + landmarks.** `VNDetectFaceLandmarksRequest` returns `[VNFaceObservation]` where each observation carries a `landmarks: VNFaceLandmarks2D?` with `allPoints` (and the named groups: `faceContour`, `leftEye`, `rightEye`, `leftEyebrow`, `rightEyebrow`, `nose`, `noseCrest`, `medianLine`, `outerLips`, `innerLips`). Detection and landmark inference are one request, one pass — we don't need a separate `VNDetectFaceRectanglesRequest`. Built into Vision; runs on the Neural Engine on Apple Silicon.
2. **Detection cadence.** Detection runs at a reduced cadence (default every 3 frames at 30 fps; configurable). Between inference frames we interpolate landmarks linearly between cached endpoints.
3. **Temporal smoothing.** One-Euro filter on each landmark point (`minCutoff = 1.0 Hz`, `beta = 0.007` — same parameters as Phase 33). Kills jitter without lag.
4. **Mesh warp.** A Metal compute pass takes the source frame + a per-vertex `(srcUV, dstUV)` map derived from the landmark deltas under the user's slider parameters. Standard barycentric interpolation across triangles.
5. **Primary face.** Largest face × proximity-to-centre score. If multiple faces tie, the leftmost wins (deterministic). Multi-face is explicitly out of v1.
6. **Skin-mask upgrade.** Phase 32a's chroma mask gets multiplied by a face-region polygon mask derived from the landmark contour, so smoothing only kicks in where skin AND the face polygon agree. Phase 32a remains usable without landmarks (chroma-only fallback) when face detection fails.
7. **Privacy.** Raw landmarks, face coordinates, and inferred geometry **never persist** to `ProjectDoc` or bundles. Only the slider parameters + per-clip enable flag persist. Diagnostics exclude face-derived data.

## Trade-offs

- Vision's `VNDetectFaceLandmarksRequest` ships with macOS; no model download. Quality is good enough for the SUBTLE defaults we ship; we surface a strength cap to keep the result restrained even when sliders go high.
- Detect every 3 frames + interpolate is a 3× cost saving at perceptually-indistinguishable quality.
- One-Euro at the same parameters as Phase 33 keeps user-facing temporal-stability behaviour consistent across reframe + beauty.

## Risks

- Landmark accuracy drops at extreme yaw or partial occlusion; the warp gracefully degrades (slider effect attenuates as landmark confidence drops, per landmark).
- Wide-angle distortion from very-short focal-length sources can produce odd warp results; the design accepts this and warns in the UI.

## Non-goals

- Makeup transfer.
- Face swap or any identity alteration.
- Age / gender / demographic "filters".
- Body reshaping.
- Automatic "beautify on" without explicit user action.
