# Requirements: LocalCutCore Swift Package

## R1 — Package structure

- [x] **R1.1** A local SwiftPM package exists at `Packages/LocalCutCore/` with
      `swift-tools-version: 6.0` and `platforms: [.macOS("26.0")]`.
- [x] **R1.2** The package exposes a single library product `LocalCutCore`.
- [x] **R1.3** The package compiles with `swift build --package-path Packages/LocalCutCore`.

## R2 — Migrated modules

- [x] **R2.1** `Capabilities` module: `CapabilityTier`, `CapabilityFeature`,
      `CapabilityVerdict`, `Capabilities` with probe and resolver.
- [x] **R2.2** `Models` module: `Clip`, `Track`, `CaptionTrack`, `ColourGrade`,
      `SkinSmoothEffect`, `Effect`, `TransitionType`, `Transition`, `RGBAColour`,
      `CaptionStyle`, `WordTiming`, `CaptionLine`, `TimelineMarker`, `TrackInput`,
      `VolumeEnvelope`, `AudioMeterSnapshot`, `WorkingColourSpace`, sanitization
      extensions (`CMTime.sanitized`, `CGSize.sanitized`,
      `CGAffineTransform.sanitized`), `CMTimeCode`, `TransformCode`, `Interpolatable`.
- [x] **R2.3** `Keyframes` module: `Keyframe<T>`, `Keyframed<T>` with interpolation.
- [x] **R2.4** `Transitions` module: `TransitionLayout` with cuts, overlaps,
      ripple, placements, authored-times mapping.
- [x] **R2.5** `RenderPlanning` module: `VisibleSegment`, `PlannedUnit`, `planUnits()`,
      `subRampVolumes()`, `fitTransform()`, `activeCaptionItems()`.
- [x] **R2.6** `DocumentTypes` module: `ProjectDocument`, `MediaRef`, `TrackDoc`,
      `ClipDoc`, `TransitionDoc`, `AudioBusDoc`, `TrackInputDoc`, `CaptionTrackDoc`.
- [x] **R2.7** `CaptionImporter` module: SRT/VTT parse logic (`parseLines`,
      `parseSRT`, `parseVTT`, `parseTiming`, `parseTimestamp`).
- [x] **R2.8** `CaptionPresets` module: `CaptionPresetV1`, `BuiltInCaptionPresets`,
      `CaptionPresetIO` (encode/decode/read/write).
- [x] **R2.9** `DiagnosticsBridge` module: thread-safe ring buffer with
      `OSAllocatedUnfairLock`.
- [x] **R2.10** `TimeFormatting` module: `TimeFormatting.timecode()`.
- [x] **R2.11** `AudioBusMixing` module: `AudioBusMixing.baselineVolume()`.

## R3 — App integration

- [x] **R3.1** The Xcode project references the local package via
      `XCLocalSwiftPackageReference`.
- [x] **R3.2** The app target links `LocalCutCore` via `packageProductDependencies`.
- [x] **R3.3** All app files that use migrated types have `import LocalCutCore`.
- [x] **R3.4** All test files that use migrated types have `import LocalCutCore`.
- [x] **R3.5** `xcodebuild -scheme "LocalCut Studio" -destination 'platform=macOS' build`
      succeeds.

## R4 — Package tests

- [x] **R4.1** `swift test --package-path Packages/LocalCutCore` passes (23 tests).
- [x] **R4.2** Package tests cover `Capabilities` tier ordering, snapshot stability,
      non-empty reasons, and per-feature gating.

## R5 — App tests

- [x] **R5.1** `xcodebuild test` passes — no test count regression from the
      pre-migration baseline.

## R6 — Code quality

- [x] **R6.1** No `nonisolated` annotations on package type declarations (redundant
      in SwiftPM context).
- [x] **R6.2** `import Observation` is explicit in `TrackTypes.swift` for `@Observable`.
- [x] **R6.3** `AudioMeterSnapshot.silent` is a computed property (`static var`) so
      `sampledAt` is never stale.
- [x] **R6.4** `Track` and `CaptionTrack` use `@MainActor` isolation (not
      `@unchecked Sendable`) to make the threading contract explicit and
      compiler-enforced.
- [x] **R6.5** Pure functions that only need data from `@MainActor` types accept
      value-type snapshots (`[[Clip]]`, `[(defaultStyle:lines:isMuted:)]`) so
      geometry/planning logic can run off the main actor.
