# Design: Colour Management + Scopes (P21 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 38 (look packs).

## Goal

Give the project an explicit **working colour space** that follows every frame through preview and export, and surface that frame to the editor through **scopes** (waveform + vectorscope). The look-pack work that follows can't trust grading decisions made over an untagged sRGB-assumed pipeline; this spec turns that assumption into a project setting and gives the user objective measurements of the result.

## Approach

1. **One project-wide working space**. `Project.workingColourSpace` defaults to **sRGB** and can change to Display P3, Rec.709, or Rec.2020. The setting is Codable, undoable, and threads through `ProjectDocument`.
2. **The compositor switches on it**, not the global static. `EffectCompositor.sharedCIContext` becomes a per-space cache (keyed by `WorkingColourSpace`) so a project edit doesn't have to throw away an existing context. The compositor reads the space from the `EffectCompositionInstruction` it's already handed.
3. **Output buffers carry the tag**. Every `CVPixelBuffer` produced by `startRequest(_:)` gets `kCVImageBufferColorPrimariesKey` / `kCVImageBufferTransferFunctionKey` / `kCVImageBufferYCbCrMatrixKey` attachments matching the working space, so the downstream `AVAssetExportSession` / `AVAssetWriter` writes a colour-tagged movie instead of silently flattening to sRGB.
4. **Title-raster cache invalidates on space change**. A cached caption raster was rendered against a specific working space; changing the space must purge it. The existing `TitleRasterer.purge()` seam covers this — `setWorkingColourSpace(_:)` calls it.
5. **Scopes sample the compositor, throttled**. A `ScopeSampler` shared instance receives each rendered `CIImage`; it gates itself to ≤30 Hz so a 60 fps preview only doubles render cost once, and only when the panel is visible (`enabled = false` is a fast no-op). The sampler is fully nonisolated (`nonisolated static let shared`, lock-guarded state); the compositor reaches it from off-main, so anchoring it to `MainActor` would force the entire sampling path through the main actor.
6. **Single bounded readback**. The sampler scales the composed frame into a capped `.RGBAf` buffer (max 160×90) with one `CIContext.render`, then derives both scopes from those pixels. Waveform bins use BT.709 luma; vectorscope emits one point per readback pixel instead of an 8×8 average grid.
7. **Float readback**. `.RGBAf` avoids 8-bit clamping before luma/chroma conversion, while the bounded buffer keeps the CPU work predictable.
8. **Out-of-order publish drop**. `publish(_:)` compares the incoming sample's `generatedAt` to the stored sample and silently drops older arrivals — AVFoundation dispatches frame requests concurrently, so two `publish` calls can race and an older frame must not overwrite a newer one.
9. **`ScopesView` is a SwiftUI panel** rendered with `Canvas`. The sampler holds no SwiftUI / Observation state (it can't, given it's reached from off-main); the view runs a lightweight task that polls `(sample, revision)` and only mutates SwiftUI state when `revision` changes, so an idle paused frame does not redraw at 30 Hz.

## Working space → CV constants

| Space | `CGColorSpace` | Primaries | Transfer | YCbCr matrix |
|---|---|---|---|---|
| sRGB (default) | `CGColorSpace.sRGB` | `ITU_R_709_2` | `sRGB` | `ITU_R_709_2` |
| Display P3 | `CGColorSpace.displayP3` | `P3_D65` | `sRGB` | `ITU_R_709_2` |
| Rec.709 | `CGColorSpace.itur_709` | `ITU_R_709_2` | `ITU_R_709_2` | `ITU_R_709_2` |
| Rec.2020 (SDR) | `CGColorSpace.itur_2020` | `ITU_R_2020` | `ITU_R_709_2` | `ITU_R_709_2` |

Rec.2020 here means **SDR Rec.2020 only**: only the *gamut* primaries are widened; the transfer function and YCbCr matrix stay on the BT.709 SDR values that AVFoundation reliably round-trips through pixel-buffer attachments. HDR transfer functions (PQ / HLG) and constant-luminance Rec.2020 matrix variants are out of scope for v1; Phase 39's vertical-finishing spec or a future HDR spec can extend the table without breaking the on-disk format.

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
    nonisolated static let shared = ScopeSampler()
    nonisolated static let minIntervalSeconds = 1.0 / 30.0

    nonisolated func shouldSample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool  // checks `enabled` + 1/30s gate (monotonic clock)
    nonisolated func sample(image:context:colorSpace:) -> ScopeSample
    nonisolated func publish(_ sample: ScopeSample)  // drops out-of-order arrivals
    nonisolated var snapshot: (sample: ScopeSample?, revision: Int)  // pulled by view
}
```

- **Readback**: The frame is translated to origin and scaled into a bounded buffer (max 160×90, no upscaling) in one GPU pass, then read back with `.RGBAf`.
- **Waveform**: Every readback pixel is folded into BT.709 luma and binned into 32 columns × 64 luma buckets. Each column normalises independently against its own max bin; cross-column luma magnitude is not preserved (a per-row average is a Phase 38 extension).
- **Vectorscope**: Every readback pixel is converted to (U, V) chroma offsets, so the trace is a dense scatter rather than an 8×8 cell-average proxy. The Canvas plots the scatter on a circular UV plane with 75% colour-bar target boxes.

Per-frame cost is dominated by one small readback plus CPU loops over at most 14,400 pixels; on Apple Silicon this is cheaper and more predictable than 32 separate histogram renders. The 30 Hz cap means a 60 fps preview pays this once per two frames, and never when the panel is hidden (the sampler shortcuts on `enabled == false` before any filter work).

## UI

- **Inspector → Project → Colour** panel: working-space picker (`Picker` of `WorkingColourSpace.allCases`) + `Toggle("Show scopes")`. Both undoable via `setWorkingColourSpace(_:)` and a coalesced `showScopes` model flag.
- **Preview overlay**: when `model.showScopes` is on, a `ScopesView` panel sits along the preview's trailing edge. The view starts an async refresh task, sets `enabled = true`, polls `ScopeSampler.shared.snapshot`, and only updates `@State` when the revision changes. On disappearance it clears the sampler (`enabled = false`), which bumps the revision so no stale frame remains on the next appearance.

## Persistence

`ProjectDocument` gains `workingColourSpace`; the decoder reads it through the raw `String` so an **unknown value** (a future schema's wider-gamut case) decodes as `.sRGB` instead of throwing — the existing `schemaVersion > current` guard in `EditorModel.load(document:from:)` then runs as intended and the open path never fails outright on a wider-gamut document. Legacy documents (no key) also decode as `.sRGB`. `schemaVersion` bumps to 3.

`ProjectState` (undo snapshot) also carries the value so the per-space CIContext / cache purge replays on undo.

`EditorModel.load(document:from:)` unconditionally calls `EffectCompositor.purgeCaptionRasterCache()` before installing the document — `releaseSession()` clears tracks but not the rasterer, and reopening the same project with stable `CaptionLine` UUIDs under a different working space would otherwise reuse stale rasters from the previous session.

## Trade-offs

- **Per-space CIContext cache vs. one context** — Apple's `CIContext.workingColorSpace` is constructor-only. We pay a few extra Metal-context bytes for predictable per-space behaviour rather than juggling render-time conversions.
- **CV attachments per buffer vs. one configuration-level setting** — `AVVideoComposition.Configuration` exposes `colorPrimaries` / `colorTransferFunction` / `colorYCbCrMatrix`, but those describe the *source*; the per-buffer attachments are what AVAssetExportSession writes into the output file. Setting both keeps preview and export in sync.
- **Throttle the sampler vs. opt in per frame** — A 30 Hz cap is enough for the eye and keeps the compositor's hot path predictable; opting in per frame would expose to the entire pipeline.
- **Bounded readback vs. full-resolution scatter** — A full-resolution vectorscope would make every sampled preview frame read back millions of pixels. The 160×90 cap gives a dense, stable scatter while keeping the compositor path predictable; a future Metal kernel can raise fidelity without changing the view contract.
- **Calling purge from the model vs. observing the project** — The model already knows when the space changes (its setter) and owns the seam; an observation-driven purge would re-purge across undo replays whether or not the space actually changed.

## Risks

- **Display P3 / Rec.2020 export** has not been validated against a calibrated reference; the working space is declared correctly but the LUTs in `feature-colour-grading` were tuned for sRGB. We keep sRGB as default and document the others as "advanced — verify on a reference monitor".
- **Scope readback hits CPU each sampled frame** — On Apple Silicon this is unified memory and cheap, but the readback is still bounded to 160×90 and gated to 30 Hz. We do not target Intel macOS 26+, so this is acceptable but worth noting.
- **Sampler state is a global singleton**. Tests that mutate `ScopeSampler.shared.enabled` must reset it; the test target's `init()` for each `@Test` is fine because the tests pass their own `CIContext` and call `sample(...)` directly rather than relying on the shared compositor flow.

## Non-goals

- HDR (PQ / HLG transfer) — out of scope for v1.
- Per-clip colour space — every clip is interpreted in the project's working space.
- 3D vectorscope or RGB parade — the panel offers waveform + vectorscope only; richer views are a Phase 38 extension.
- Disk-backed scope history — every sample is the live frame; there is no scrubbing history.
