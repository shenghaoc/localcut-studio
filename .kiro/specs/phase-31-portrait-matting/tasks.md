# Tasks: Phase 31 — Portrait Video Matting

> Status: **Proposed**. Depends on `feature-colour-grading`; blocked on macOS 27 leaving beta.

## Engine

- [ ] **T1.1** Tier A: `VNGeneratePersonSegmentationRequest` wrapper feeding the compositor.
- [ ] **T1.2** Tier B: Core AI MODNet loader with manifest + SHA-256; `URLSession` download with progress.
- [ ] **T1.3** Optional RVM (recurrent) loader with per-clip session + reset policy.

## Pipeline

- [ ] **T2.1** `IOSurface` `CVPixelBuffer` → Vision / Core AI → `CVPixelBuffer` alpha → `MTLTexture` route.
- [ ] **T2.2** Compositor matte / blur passes (CIKernel or Metal compute).
- [ ] **T2.3** Effect modes: `remove`, `replace`, `blur`.
- [ ] **T2.4** Proxy-resolution preview / full-resolution export split.

## Capability gating

- [ ] **T3.1** Probe-driven Core AI compute-unit selection.
- [ ] **T3.2** Realtime-sustainability check; surface "export-only" downgrade when needed.

## Verification

- [ ] **T4.1** Temporal-stability test on a panning fixture.
- [ ] **T4.2** Determinism test.
- [ ] **T4.3** Smoke: enable → scrub → export.
- [ ] **T4.4** `xcodebuild` (Debug, macOS) green.
