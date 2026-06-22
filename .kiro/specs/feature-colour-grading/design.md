# Design: Colour Grading

> Status: **Implemented**. Shipped in [#2](https://github.com/shenghaoc/localcut-studio/pull/2). See [tasks.md](./tasks.md) for the per-box source citations.

## Approach

Introduce a custom `AVVideoCompositing` (`EffectCompositor`) set as `videoComposition.customVideoCompositorClass`. It receives each frame request, renders every active source frame through its clip's Core Image effect chain, applies the existing transform/opacity, and composites bottom-to-top into the render buffer. Because the same `AVVideoComposition` is attached to both the `AVPlayerItem` and the `AVAssetExportSession`, preview and export share the path.

## Pieces

- **Model**: `Effect` value type (discriminated by kind) + `[Effect]` on `Clip`. A `ColourGrade` struct groups exposure/contrast/saturation/temperature/tint; LUT referenced by security-scoped bookmark.
- **`EffectChain` → `CIFilter`s**: map parameters to `CIColorControls`, `CITemperatureAndTint`, `CIExposureAdjust`, and `CIColorCube`/`CIColorCubeWithColorSpace` for the LUT. Compose with a shared `CIContext` (Metal device).
- **`EffectCompositor: NSObject, AVVideoCompositing`**: implements `startRequest(_:)`, resolves which clips/tracks are active for the request time (via instruction metadata), renders each through its chain, and draws into the destination pixel buffer; honours `requiredPixelBufferAttributesForRenderContext`.
- **Instruction metadata**: extend the builder so each instruction/layer carries the clip's effect chain (custom `AVVideoCompositionInstructionProtocol` instruction subclass).
- **UI**: `InspectorView` gains a "Colour" section bound to the selected clip's grade; LUT import via `.fileImporter`.

## Trade-offs

- Custom compositor is more code than `applyingCIFilters`, but it's the only path that keeps multi-track layering **and** per-clip effects in one shared pipeline.
- A single shared `CIContext` (Metal) avoids per-frame context creation; reuse across preview and export.

## Risks

- Colour-management correctness (working space, LUT colour space) — validate against known references.
- Throughput on 4K; mitigate with proxy/preview resolution later if needed.
