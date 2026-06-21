# Requirements: Phase 31 — Portrait Video Matting

## R1 — Engine

- **R1.1** `VNGeneratePersonSegmentationRequest` with `qualityLevel = .accurate` is the engine.
- **R1.2** Hosts where Vision cannot sustain realtime preview see an explicit "export-only" downgrade or "unavailable" message from the capability probe.

## R2 — Pipeline

- **R2.1** Zero-copy: `IOSurface`-backed `CVPixelBuffer` from `AVAssetReader` → Vision → alpha texture → compositor.
- **R2.2** Effect modes: `remove` (alpha), `replace` (alpha + background source), `blur` (mask-driven gaussian).
- **R2.3** Preview runs at proxy resolution; export runs at full project resolution.

## R3 — Stability

- **R3.1** Temporal stability check on fixture footage: frame-to-frame alpha delta below a documented bound (no flicker).
- **R3.2** Same alpha output for the same `(asset, frame, mode)` across app restarts.

## R4 — Persistence

- **R4.1** Effect parameters survive bundle round-trip.
- **R4.2** The background source for `replace` mode persists as a clip reference in `ProjectDoc`.

## R5 — Performance

- **R5.1** Realtime preview at proxy resolution on Apple Silicon (M2-class).
- **R5.2** Hosts that cannot sustain realtime at proxy surface an explicit "export-only" downgrade.

## R6 — Verification

- **R6.1** Temporal-stability test on a panning fixture clip.
- **R6.2** Smoke: enable matting → scrub → export → preview / export pixel match at sampled times.
- **R6.3** `xcodebuild` (Debug, macOS) green; no test count regression.
