# Tasks: Colour Management + Scopes

> Status: **Implemented**. Ships as a prerequisite for Phase 38 (look packs).

## Model

- [x] **T1.1** Define `WorkingColourSpace` (Codable, CaseIterable, Sendable) with sRGB / Display P3 / Rec.709 / Rec.2020 cases and the documented mapping to `CGColorSpace` + CV constants.
- [x] **T1.2** Add `Project.workingColourSpace` (default `.sRGB`) and `EditorModel.setWorkingColourSpace(_:)` (undoable, purges the title-raster cache, schedules a rebuild).
- [x] **T1.3** Carry `workingColourSpace` through `ProjectState` (undo snapshot) and `ProjectDocument` (Codable round-trip, lenient decode → `.sRGB` for legacy documents); bump `currentSchemaVersion` accordingly.

## Engine

- [x] **T2.1** Extend `EffectCompositionInstruction` to carry the working space; `CompositionBuilder` propagates `project.workingColourSpace` into every instruction.
- [x] **T2.2** Replace `EffectCompositor.sharedCIContext` with a per-space cache keyed on `WorkingColourSpace` (Metal device, working-space-specific `workingColorSpace`).
- [x] **T2.3** In `startRequest(_:)`, render through the per-space context, then tag the destination `CVPixelBuffer` with the working-space primaries / transfer / YCbCr matrix attachments (`applyColourAttachments(_:to:)`).
- [x] **T2.4** Expose `EffectCompositor.purgeCaptionRasterCache()` / `captionRasterCacheCount` so the model and tests can drive the seam.

## Scopes

- [x] **T3.1** Implement `ScopeSampler` (`@unchecked Sendable`, lock-guarded state) with `shouldSample()` 30 Hz gate, `sample(image:context:colorSpace:)`, and `publish(_:)`.
- [x] **T3.2** Implement waveform sampling with `CIFilter.areaHistogram` (32 column slices, 64 bins each) and vectorscope sampling with `CIFilter.areaAverage` (8×8 grid of UV averages).
- [x] **T3.3** Implement `ScopesView` (SwiftUI + Canvas) rendering waveform columns and vectorscope points; the view sets `ScopeSampler.shared.enabled` to mirror its visibility.
- [x] **T3.4** Hook the sampler into `EffectCompositor.startRequest(_:)` — call it after compositing, only when `shouldSample()` says yes.

## UI

- [x] **T4.1** Inspector Project section gains a Colour panel with a working-space `Picker` and a `Toggle("Show scopes")`; both undoable.
- [x] **T4.2** PreviewView shows the `ScopesView` panel alongside the preview when `model.showScopes` is on.

## Verification

- [x] **T5.1** Test: `setWorkingColourSpace(_:)` empties the shared caption-raster cache (R6.1).
- [x] **T5.2** Test: `applyColourAttachments(_:to:)` writes the documented colour primaries / transfer function / YCbCr matrix onto a `CVPixelBuffer` (R6.2).
- [x] **T5.3** Test: `ScopeSampler.sample(image:context:colorSpace:)` on a non-black `CIImage` produces a waveform with at least one column with a non-zero bin (R6.3).
- [x] **T5.4** Test: a Codable round-trip of a `Project` with a non-default working space restores it; a legacy document without the key decodes as `.sRGB`.
- [x] **T5.5** `xcodebuild` (Debug, macOS) green; no test count regression.

## Roadmap

- [x] **T6.1** Move the "Colour management + scopes" row from the **Open infra** table to the **Existing spec** table in `.kiro/specs/ROADMAP.md`.
