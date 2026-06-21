# Design: Phase 31 — Portrait Video Matting

> Status: **Proposed**. Target tag: **v0.2.2**. Blocked on macOS 27 leaving beta.

## Goal

Person matting as a per-clip effect, zero-copy through the existing AVFoundation / Metal pipeline. The browser-editor ships **MODNet** as an ONNX model on ORT-WebGPU because the web platform has no native person-segmentation API. The native port doesn't need to vendor a model: **Apple ships person segmentation as a first-party framework (`Vision`)** — no model bundle, no manifest, no SHA-256 pinning, no download UX.

## Prerequisites

- `feature-colour-grading`'s custom `AVVideoCompositing` + per-clip effect chain (the matte texture is composited above the clip's other effects).
- Keyframes (not yet specced) for `strength` / `mode` over time.

## Approach

1. **Engine.** `VNGeneratePersonSegmentationRequest` with `qualityLevel = .accurate`. Apple ships the segmentation models with the OS; macOS 27 brings refreshed on-device models. Runs on the Neural Engine on Apple Silicon.
2. **Zero-copy pipeline.**
   ```
   CMSampleBuffer → CVPixelBuffer (IOSurface-backed)
                  ↓
              VNGeneratePersonSegmentationRequest
                  ↓
              CVPixelBuffer alpha (single channel) → MTLTexture
                  ↓
              Compositor matte / blur passes (CIKernel or Metal compute)
   ```
   No CPU pixel round-trip. `IOSurface`-backed `CVPixelBuffer` from the asset reader is fed directly to Vision; the alpha output is sampled into the compositor's Metal-backed `CIContext`.
3. **Effect modes.** `remove` (alpha → transparency, no source frame needed beyond the matted clip itself), `replace` (alpha key over a background source), `blur` (mask-driven gaussian on the inverse alpha).
   - `replace` mode requires the background source to be a clip on a track in the composition placed UNDER the matted clip — a custom `AVVideoCompositing` can only read frames the composition fed it (`request.sourceFrame(byTrackID:)`); it cannot decode an arbitrary asset on the fly. The inspector's "background" picker therefore creates / inserts a real clip behind the matted clip rather than referencing media by id alone; the resulting composition has the alpha-keyed compositing instruction reference both source track IDs.
4. **Preview vs export.** Preview runs at proxy resolution if `feature-colour-grading`'s proxy path is wired; export runs at full project resolution. A guided-upsample Metal compute pass optionally refines model-resolution alpha to full size.
5. **Capability gating.** Hosts that can't sustain realtime preview on their hardware see an explicit "export-only" downgrade rather than a silent hang.

## Trade-offs

- Apple-provided model only — no BYO MODNet / RVM custom model. We accept Vision's edge quality as the v1 baseline. The browser-editor needed MODNet because the web has no native segmentation API; we don't.
- Vision's segmentation API quality varies across macOS versions; we hold this phase for macOS 27 so the ML tier shares one OS baseline.

## Risks

- Vision segmentation quality drops on extreme yaw / partial occlusion; deliberate non-goal to match studio matting tools.
- Apple-Silicon-only feasible at preview rate; Intel Macs see the feature as export-only or unavailable depending on probe.

## Non-goals

- Bundled or downloadable MODNet / RVM / custom segmentation models.
- General object segmentation (SAM-class).
- Chroma-key green screen — implement as a separate trivial Core Image filter if not already present; not bundled into this spec.
- Guaranteed hair-strand studio quality.
