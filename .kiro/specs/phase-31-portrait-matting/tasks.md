# Tasks: Phase 31 — Portrait Video Matting

> Status: **Proposed**. Depends on `feature-colour-grading`; blocked on macOS 27 leaving beta.

## Engine

- [ ] **T1.1** `VNGeneratePersonSegmentationRequest` wrapper feeding the compositor; `qualityLevel = .accurate`.

## Pipeline

- [ ] **T2.1** `IOSurface` `CVPixelBuffer` → Vision → `CVPixelBuffer` alpha → `MTLTexture` route.
- [ ] **T2.2** Compositor matte / blur passes (CIKernel or Metal compute).
- [ ] **T2.3** Effect modes: `remove`, `replace`, `blur`.
- [ ] **T2.4** Proxy-resolution preview / full-resolution export split.

## Capability gating

- [ ] **T3.1** Sustainability check; surface "export-only" or "unavailable" downgrade when needed.

## Verification

- [ ] **T4.1** Temporal-stability test on a panning fixture.
- [ ] **T4.2** Smoke: enable → scrub → export.
- [ ] **T4.3** `xcodebuild` (Debug, macOS) green.
