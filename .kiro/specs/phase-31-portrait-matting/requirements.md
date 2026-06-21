# Requirements: Phase 31 — Portrait Video Matting

## R1 — Engine

- **R1.1** Tier A: `VNGeneratePersonSegmentationRequest` (`qualityLevel = .accurate`) is the default when available.
- **R1.2** Tier B: optional Core ML matting model (MODNet default, RVM optional) with manifest + SHA-256.
- **R1.3** `MLComputeUnits` selected by the capability probe; Neural Engine preferred on Apple Silicon.

## R2 — Pipeline

- **R2.1** Zero-copy: `IOSurface`-backed `CVPixelBuffer` from `AVAssetReader` → Vision / Core ML → alpha texture → compositor.
- **R2.2** Effect modes: `remove` (alpha), `replace` (alpha + background source), `blur` (mask-driven gaussian).
- **R2.3** Preview runs at proxy resolution; export runs at full project resolution.
- **R2.4** Recurrent models reset their per-clip state on seek and on shot boundaries.

## R3 — Stability

- **R3.1** Temporal stability check on fixture footage: frame-to-frame alpha delta below a documented bound (no flicker).
- **R3.2** Deterministic alpha output on repeated runs in test mode.
- **R3.3** Same alpha for the same `(asset, frame, model, mode)` across app restarts.

## R4 — Persistence

- **R4.1** Effect parameters + model pin survive bundle round-trip.
- **R4.2** The background source for `replace` mode persists as a clip reference in `ProjectDoc`.

## R5 — Performance

- **R5.1** Realtime preview at proxy resolution on Apple Silicon (M2-class) with the Tier A engine.
- **R5.2** Hosts that cannot sustain realtime at proxy surface an explicit "export-only" downgrade.

## R6 — Verification

- **R6.1** Temporal-stability test on a panning fixture clip.
- **R6.2** Determinism test for repeated runs.
- **R6.3** Smoke: enable matting → scrub → export → preview / export pixel match at sampled times.
- **R6.4** `xcodebuild` (Debug, macOS) green; no test count regression.
