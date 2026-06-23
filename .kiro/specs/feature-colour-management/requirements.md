# Requirements: Colour Management + Scopes

## R1 — Working colour space

- **R1.1** `Project.workingColourSpace` is a Codable enum (`sRGB`, `displayP3`, `rec709`, `rec2020`) defaulting to `sRGB`.
- **R1.2** Changing it goes through one undoable step (`setWorkingColourSpace(_:)`).
- **R1.3** A change calls `TitleRasterer.purge()` so cached caption rasters re-render in the new space.
- **R1.4** Each working space maps to a documented `CGColorSpace`, `CVImageBufferColorPrimaries`, `CVImageBufferTransferFunction`, and `CVImageBufferYCbCrMatrix` constant — see [design](./design.md#working-space--cv-constants).

## R2 — Compositor

- **R2.1** `EffectCompositor` uses a Metal-backed `CIContext` whose `workingColorSpace` is set from the project's working space, cached per space.
- **R2.2** Every `CVPixelBuffer` returned by `startRequest(_:)` carries the working-space colour primaries, transfer function, and YCbCr matrix as buffer attachments (so `AVAssetExportSession` / `AVAssetWriter` write a colour-tagged movie).
- **R2.3** The instruction passed to the compositor carries the working space; the compositor never reads from `EditorModel` (no actor crossing).

## R3 — Scopes

- **R3.1** A `ScopeSampler` shared instance produces a `Sample` containing both a waveform (per-X-column luma histogram) and a vectorscope (UV scatter points) from a `CIImage`.
- **R3.2** The sampler gates itself to ≤ 30 Hz; when `enabled == false` it shortcuts to a no-op before any filter work.
- **R3.3** Sampling performs one bounded `.RGBAf` `CIContext` readback, builds waveform bins from BT.709 luma in one CPU pass, and emits one vectorscope point per readback pixel.
- **R3.4** `ScopesView` renders the latest sample with SwiftUI `Canvas`. It sets `enabled = true` while visible, clears it on disappear, and only invalidates SwiftUI state when the sampler `revision` changes.
- **R3.5** Sample data for a non-black frame has at least one waveform column with non-zero bins.

## R4 — UI

- **R4.1** The Inspector's Project section gains a Colour panel with a working-space `Picker` and a `Toggle("Show scopes")`.
- **R4.2** When the toggle is on, a scopes panel is visible alongside the preview.
- **R4.3** The picker shows every `WorkingColourSpace.allCases` value with its human-readable name.

## R5 — Persistence

- **R5.1** `ProjectDocument` round-trips `workingColourSpace`; legacy documents decode it as `sRGB`.
- **R5.2** The undo snapshot (`ProjectState`) carries the value so `applyState(_:)` restores it.

## R6 — Verification

- **R6.1** Unit test: `setWorkingColourSpace(_:)` empties the shared caption-raster cache (the `TitleRasterer.purge()` seam fires).
- **R6.2** Unit test: a destination pixel buffer carries the colour primaries / transfer function / YCbCr matrix attachments matching the project's working space.
- **R6.3** Unit test: `ScopeSampler.sample(image:context:colorSpace:)` over a non-black `CIImage` produces a waveform with at least one column with a non-zero bin and a dense per-pixel vectorscope trace.
- **R6.4** Unit test: a split black/white frame lands in dark and bright waveform bins from the single readback.
- **R6.5** Unit test: disabling the sampler clears the latest sample and bumps `revision` so the UI clears stale pixels without a timer redraw.
- **R6.6** Existing test count does not regress. `xcodebuild` (Debug, macOS) is green.
