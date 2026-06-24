# Tasks: LocalCutCore Swift Package

> Status: **Implemented**.

## Package setup

- [x] **T1.1** Create `Packages/LocalCutCore/Package.swift` (swift-tools 6.0,
      macOS 26, library product).
- [x] **T1.2** Create module directory structure (Capabilities, Models, Keyframes,
      Transitions, RenderPlanning, TimeFormatting, Diagnostics).
- [x] **T1.3** Write `README.md` with structure, migration status, and procedure.

## Capabilities migration

- [x] **T2.1** Move `Capabilities.swift` into `Sources/LocalCutCore/Capabilities/`.
- [x] **T2.2** Mark all public API symbols `public`.
- [x] **T2.3** Move `CapabilitiesTests.swift` into `Tests/LocalCutCoreTests/`,
      switch to `import LocalCutCore`.

## Models migration

- [x] **T3.1** Create `TimeExtensions.swift`: `CMTime.sanitized`, `CGSize.sanitized`,
      `CGAffineTransform.sanitized`, `CMTimeCode`, `TransformCode`, `Interpolatable`.
- [x] **T3.2** Create `Models.swift`: `WorkingColourSpace`, `TrackKind`, `ColourGrade`,
      `SkinSmoothEffect`, `Effect`, `TransitionType`, `Transition`, `Clip`, `RGBAColour`,
      `StrokeStyle`, `ShadowStyle`, `GlowStyle`, `PillStyle`, caption style/animation
      enums, `CaptionStyle`, `WordTiming`, `CaptionLine`, `TimelineMarker`, `TrackInput`,
      `VolumeEnvelope`, `AudioMeterSnapshot`.
- [x] **T3.3** Create `TrackTypes.swift`: `Track`, `CaptionTrack` (`@Observable`
      classes with `@MainActor` isolation).
- [x] **T3.4** Create `AudioBusMixing.swift`: `AudioBusMixing.baselineVolume()`.

## Keyframes migration

- [x] **T4.1** Create `Keyframes.swift`: `Keyframe<T>`, `Keyframed<T>` with
      sorted insertion, binary-search interpolation, and Codable round-trip.

## Document types migration

- [x] **T5.1** Create `DocumentTypes.swift`: `ProjectDocument`, `MediaRef`,
      `TrackDoc`, `ClipDoc`, `TransitionDoc`, `AudioBusDoc`, `TrackInputDoc`,
      `CaptionTrackDoc` with Codable snapshot helpers.

## Transitions migration

- [x] **T6.1** Create `TransitionLayout.swift`: `TransitionLayout` enum with
      `Cut`, `Placement`, `Piece`, `effectiveOverlap`, `pieces`, `orderedOverlaps`,
      `cuts`, `shift`, `authoredTimes`, `placements`.

## Render planning migration

- [x] **T7.1** Create `RenderPlanning.swift`: `VisibleSegment`, `PlannedUnit`,
      `planUnits()`, `subRampVolumes()`, `fitTransform()`, `activeCaptionItems()`.

## Caption modules migration

- [x] **T8.1** Create `CaptionImporter.swift`: SRT/VTT parse logic.
- [x] **T8.2** Create `CaptionPresets.swift`: built-in presets + `.lccaption` I/O.

## Diagnostics migration

- [x] **T9.1** Create `DiagnosticsBridge.swift`: thread-safe ring buffer.

## Time formatting migration

- [x] **T10.1** Create `TimeFormatting.swift`: `timecode()` display formatter.

## App integration

- [x] **T11.1** Wire `Packages/LocalCutCore` into the Xcode project
      (`XCLocalSwiftPackageReference` + `XCSwiftPackageProductDependency`).
- [x] **T11.2** Add `import LocalCutCore` to all app source files that use
      migrated types (~25 files).
- [x] **T11.3** Add `import LocalCutCore` to all test files (~17 files).
- [x] **T11.4** Remove extracted types from app `Models.swift` (keep only
      `MediaItem` and `Project`).
- [x] **T11.5** Remove extracted types from app `ProjectDocument.swift` (keep
      only `UTType` extension and app-specific snapshot helpers).
- [x] **T11.6** Delete app `TransitionLayout.swift`, `CaptionPresets.swift`,
      `DiagnosticsBridge.swift` (fully moved to package).
- [x] **T11.7** Slim app `CaptionImporter.swift` (removed dead `CaptionImporterCompat`
      — production code uses `CaptionImporter.parseLines` from package directly).
- [x] **T11.8** Remove `TimeFormatting` from app `PreviewView.swift`.
- [x] **T11.9** Remove extracted helpers from app `CompositionBuilder.swift`
      (`VisibleSegment`, `PlannedUnit`, `planUnits`, `subRampVolumes`, `fitTransform`).

## Review fixes

- [x] **T12.1** Remove redundant `nonisolated` annotations from all package
      source files (Gemini review).
- [x] **T12.2** Add `import Observation` to `TrackTypes.swift` (Claude review).
- [x] **T12.3** Change `AudioMeterSnapshot.silent` from `static let` to
      `static var` (Claude review).
- [x] **T12.4** Replace `@unchecked Sendable` with `@MainActor` on `Track` and
      `CaptionTrack`; update `TransitionLayout.cuts(videoTracks:)` to accept
      `[[Clip]]` and `activeCaptionItems(in:)` to accept value-type tuples
      (Claude + Gemini review).
- [x] **T12.5** Remove dead `CaptionImporterCompat` from app `CaptionImporter.swift`
      (Codex review).
- [x] **T12.6** Add explicit `import CoreGraphics` to `RenderPlanning.swift`
      (Claude review).
- [x] **T12.7** Fix bookmark nil vs empty Data comparison in `DocumentController.swift`
      (Gemini review).
- [x] **T12.8** Add bounds checking on `CaptionImporter.parseTimestamp` to prevent
      Int64 overflow from malicious SRT/VTT files (Gemini review).
- [x] **T12.9** Fix `TimeFormatting.timecode` floating-point precision and carry-over
      edge case (59.999 → 1:00.00) using `totalHundredths` decomposition
      (Gemini + Claude review).

## Verification

- [x] **T13.1** `swift test --package-path Packages/LocalCutCore` passes (30 tests).
- [x] **T13.2** `xcodebuild -scheme "LocalCut Studio" -destination 'platform=macOS' build`
      succeeds.
- [x] **T13.3** `xcodebuild test` passes — no test count regression.

## Follow-up completion

- [x] **T14.1** Port representative tests from Xcode test target to package
      `LocalCutCoreTests/` (TransitionLayout, RenderPlanning, Keyframes,
      CMTimeCode round-trips) for better CI gating coverage.
- [x] **T14.2** Make `EditorModel` thinner by decomposing into services
      (`ProjectEditingService`, `PreviewRebuildCoordinator`, `ImportService`,
      `ExportCoordinator`, `DocumentController`).
