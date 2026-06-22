# Design: Colour Management + Scopes (P21 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 38 (look packs).

## Goal

Give the project an explicit **working colour space** that follows every frame through preview and export, and surface that frame to the editor through **scopes** (waveform + vectorscope). The look-pack work that follows can't trust grading decisions made over an untagged sRGB-assumed pipeline; this spec turns that assumption into a project setting and gives the user objective measurements of the result.

## Approach

1. **One project-wide working space**. `Project.workingColourSpace` defaults to **sRGB** and can change to Display P3, Rec.709, or Rec.2020. The setting is Codable, undoable, and threads through `ProjectDocument`.
2. **The compositor switches on it**, not the global static. `EffectCompositor.sharedCIContext` becomes a per-space cache (keyed by `WorkingColourSpace`) so a project edit doesn't have to throw away an existing context. The compositor reads the space from the `EffectCompositionInstruction` it's already handed.
3. **Output buffers carry the tag**. Every `CVPixelBuffer` produced by `startRequest(_:)` gets `kCVImageBufferColorPrimariesKey` / `kCVImageBufferTransferFunctionKey` / `kCVImageBufferYCbCrMatrixKey` attachments matching the working space, so the downstream `AVAssetExportSession` / `AVAssetWriter` writes a colour-tagged movie instead of silently flattening to sRGB.
4. **Title-raster cache invalidates on space change**. A cached caption raster was rendered against a specific working space; changing the space must purge it. The existing `TitleRasterer.purge()` seam covers this — `setWorkingColourSpace(_:)` calls it.
5. **Scopes sample the compositor, throttled**. A `ScopeSampler` shared instance receives each rendered `CIImage`; it gates itself to ≤30 Hz so a 60 fps preview only doubles render cost once, and only when the panel is visible (`enabled = false` is a fast no-op). It uses `CIFilter.areaHistogram` and `CIFilter.areaAverage` over a small grid to produce per-column luma histograms (waveform) and per-cell UV averages (vectorscope).
6. **`ScopesView` is a SwiftUI panel** rendered with `Canvas`: one waveform-style histogram per X-column, one UV scatter for chroma. The view subscribes to the sampler's latest sample (Observation), redrawing only when a new sample is published — never on every frame.

## Working space → CV constants

| Space | `CGColorSpace` | Primaries | Transfer | YCbCr matrix |
|---|---|---|---|---|
| sRGB (default) | `CGColorSpace.sRGB` | `ITU_R_709_2` | `sRGB` | `ITU_R_709_2` |
| Display P3 | `CGColorSpace.displayP3` | `P3_D65` | `sRGB` | `ITU_R_709_2` |
| Rec.709 | `CGColorSpace.itur_709` | `ITU_R_709_2` | `ITU_R_709_2` | `ITU_R_709_2` |
| Rec.2020 | `CGColorSpace.itur_2020` | `ITU_R_2020` | `ITU_R_2020` | `ITU_R_2020` |

These mappings are conservative SDR choices — HDR transfer functions (PQ, HLG) and Rec.2020 non-constant-luminance matrix variations are out of scope for v1; Rec.2020 here means SDR Rec.2020 only. Phase 39's vertical-finishing spec or a future HDR spec can extend the table without breaking the on-disk format.

## Compositor hookup

```swift
final class EffectCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let workingColourSpace: WorkingColourSpace  // new
    // existing fields unchanged
}

final class EffectCompositor: NSObject, AVVideoCompositing {
    nonisolated func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // resolve space from instruction (default sRGB)
        let space = (request.videoCompositionInstruction as? EffectCompositionInstruction)?
            .workingColourSpace ?? .sRGB
        let context = Self.context(for: space)
        // … existing compose path …
        context.render(composited, to: destination, bounds: rect, colorSpace: space.cgColorSpace)
        Self.applyColourAttachments(space, to: destination)

        if ScopeSampler.shared.shouldSample() {
            let sample = ScopeSampler.shared.sample(image: composited, context: context,
                                                    colorSpace: space.cgColorSpace)
            ScopeSampler.shared.publish(sample)
        }

        request.finish(withComposedVideoFrame: destination)
    }
}
```

The CIContext cache is a `OSAllocatedUnfairLock`-guarded dictionary; one Metal context per space. The cache survives composition rebuilds.

## Sampler

```swift
final class ScopeSampler: @unchecked Sendable {
    static let shared = ScopeSampler()
    private static let minIntervalSeconds = 1.0 / 30.0

    struct Sample {
        var waveform: [WaveformColumn]   // one per X-column slice
        var vectorscope: [VectorPoint]   // one per UV-grid cell
        var generatedAt: Date
    }

    func shouldSample() -> Bool          // checks `enabled` + 1/30s gate
    func sample(image:context:colorSpace:) -> Sample
    func publish(_:)                     // bumps revision; ScopesView observes
}
```

- **Waveform**: 32 column slices. For each, `CIFilter.areaHistogram` over `count: 64` produces a 1-row CIImage; the sampler reads the bins back through the CIContext to a tiny CGImage. The Canvas stacks the columns horizontally.
- **Vectorscope**: 8×8 grid. For each cell, `CIFilter.areaAverage` produces a 1×1 image; the average RGB is converted to (U, V) chroma offsets. The Canvas plots them on a circular UV plane.

Per-frame cost is dominated by the 32 small histogram renders plus the 64 averages; on Apple Silicon they fit comfortably in the existing per-frame budget. The 30 Hz cap means a 60 fps preview pays this once per two frames, and never when the panel is hidden (the sampler shortcuts on `enabled == false` before any filter work).

## UI

- **Inspector → Project → Colour** panel: working-space picker (`Picker` of `WorkingColourSpace.allCases`) + `Toggle("Show scopes")`. Both undoable via `setWorkingColourSpace(_:)` and a coalesced `showScopes` model flag.
- **Preview overlay**: when `model.showScopes` is on, a `ScopesView` panel sits along the preview's trailing edge. The view reads from `ScopeSampler.shared` (it sets `enabled = true` on appear, `false` on disappear so a hidden panel doesn't pay sample cost).

## Persistence

`ProjectDocument` gains `workingColourSpace: String?` (raw value of the enum); legacy documents decode as `nil → .sRGB`. Bump `schemaVersion` to 3 so a v2 build that opens a v3 file is flagged as newer-schema (existing `EditorModel.load(document:from:)` guard).

`ProjectState` (undo snapshot) also carries the value so the per-space CIContext / cache purge replays on undo.

## Trade-offs

- **Per-space CIContext cache vs. one context** — Apple's `CIContext.workingColorSpace` is constructor-only. We pay a few extra Metal-context bytes for predictable per-space behaviour rather than juggling render-time conversions.
- **CV attachments per buffer vs. one configuration-level setting** — `AVVideoComposition.Configuration` exposes `colorPrimaries` / `colorTransferFunction` / `colorYCbCrMatrix`, but those describe the *source*; the per-buffer attachments are what AVAssetExportSession writes into the output file. Setting both keeps preview and export in sync.
- **Throttle the sampler vs. opt in per frame** — A 30 Hz cap is enough for the eye and keeps the compositor's hot path predictable; opting in per frame would expose to the entire pipeline.
- **Grid-based vectorscope vs. per-pixel scatter** — A per-pixel scatter would need a Metal compute kernel. The 8×8 average grid is a reasonable preview proxy; Phase 38 can swap in a richer kernel without changing the view contract.
- **Calling purge from the model vs. observing the project** — The model already knows when the space changes (its setter) and owns the seam; an observation-driven purge would re-purge across undo replays whether or not the space actually changed.

## Risks

- **Display P3 / Rec.2020 export** has not been validated against a calibrated reference; the working space is declared correctly but the LUTs in `feature-colour-grading` were tuned for sRGB. We keep sRGB as default and document the others as "advanced — verify on a reference monitor".
- **`CIFilter.areaHistogram` reads back to CPU each frame** — On Apple Silicon this is unified memory and cheap, but on Intel Macs the readback could stall. We do not target Intel macOS 26+, so this is acceptable but worth noting.
- **Sampler state is a global singleton**. Tests that mutate `ScopeSampler.shared.enabled` must reset it; the test target's `init()` for each `@Test` is fine because the tests pass their own `CIContext` and call `sample(...)` directly rather than relying on the shared compositor flow.

## Non-goals

- HDR (PQ / HLG transfer) — out of scope for v1.
- Per-clip colour space — every clip is interpreted in the project's working space.
- 3D vectorscope or RGB parade — the panel offers waveform + vectorscope only; richer views are a Phase 38 extension.
- Disk-backed scope history — every sample is the live frame; there is no scrubbing history.
