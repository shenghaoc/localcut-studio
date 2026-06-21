# Design: Phase 31 — Portrait Video Matting

> Status: **Proposed**. Target tag: **v0.2.2**. Blocked on macOS 27 leaving beta.

## Goal

Person matting as a per-clip effect, zero-copy through the existing AVFoundation/Metal pipeline. Browser-editor ships **MODNet** as an ONNX model on ORT-WebGPU with the renderer's `GPUDevice` shared with ORT (so tensors stay on-GPU). The native port uses Apple's Vision + Core ML stack — same end-to-end zero-copy story, different APIs.

## Prerequisites

- `feature-colour-grading`'s custom `AVVideoCompositing` + per-clip effect chain (the matte texture is composited above the clip's other effects).
- Keyframes (not yet specced) for `strength` / `mode` over time.

## Approach

1. **Model tiering.**
   - **Tier A (default):** Apple's built-in `VNGeneratePersonSegmentationRequest` with `qualityLevel = .accurate`. Built into Vision; no download; honours the Neural Engine; runs on the Metal device shared with the compositor.
   - **Tier B (optional higher quality):** a Core ML port of MODNet or RVM, ~26 MB on disk. Same `MLModel` is shared between preview and export through `MLPredictionOptions(usesCPUOnly: false)` and Metal-backed `MLFeatureProvider`.
2. **Zero-copy pipeline.**
   ```
   CMSampleBuffer → CVPixelBuffer (IOSurface-backed)
                  ↓
              Vision request OR Core ML predict
                  ↓
              CVPixelBuffer alpha (single channel) → MTLTexture
                  ↓
              Compositor matte / blur passes (CIKernel or Metal compute)
   ```
   No CPU pixel round-trip. `CVPixelBuffer` from the asset reader's `IOSurface` is directly fed to Vision/Core ML; the alpha output is sampled into the compositor's Metal-backed `CIContext`.
3. **Recurrent state (RVM).** If we ship RVM (recurrent), the per-clip session owns hidden state. The state resets on seeks and on shot boundaries (consistent with Phase 33). Document the reset policy in design.md.
4. **Effect modes.** `remove` (alpha → transparency), `replace` (alpha key over any timeline source as background), `blur` (mask-driven gaussian on the inverse alpha).
5. **Preview vs export.** Preview runs at proxy resolution if the render-cache spec ships a proxy path; export runs at full project resolution. Optionally a guided-upsample Metal compute pass refines model-resolution alpha to full size.
6. **Capability gating.** `MLComputeUnits` chosen by the probe: `.all` (Neural Engine preferred) on Apple Silicon, `.cpuAndGPU` on Intel. Hosts that can't sustain realtime at proxy resolution see an explicit "export-only" downgrade rather than a silent hang.

## Trade-offs

- Vision's built-in segmentation is the no-download winner; MODNet/RVM via Core ML buy noticeable edge quality on hair / wisps but require a Tier B download.
- `IOSurface`-backed `CVPixelBuffer`s give us the same zero-copy guarantee the browser version gets via `importExternalTexture` — both engines avoid CPU pixel readbacks.
- RVM's recurrent state vs MODNet's stateless single-frame model: recurrent gives better temporal stability but adds reset-on-seek complexity. We default to MODNet for v1 and call out RVM as the temporal-stability follow-up.

## Risks

- Vision's segmentation API quality varies across macOS versions; we feature-detect `qualityLevel = .accurate` and fall back gracefully.
- Core ML on Intel Macs without a discrete GPU is much slower; the probe gates UX accordingly.

## Non-goals

- General object segmentation (SAM-class) — future.
- Chroma-key green screen — implement as a separate trivial Core Image filter if not already present; do not bundle it into this spec.
- Guaranteed hair-strand studio quality.
