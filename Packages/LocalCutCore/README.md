# LocalCutCore

Pure, platform-light engine logic behind **LocalCut Studio**, factored out of the
Xcode app target so it builds and tests without SwiftUI/AppKit and without the
app's `@Observable` orchestration. The payoff is a fast iteration loop:

```sh
swift test --package-path Packages/LocalCutCore
```

CI runs this as a gating job *before* the expensive `xcodebuild` test run, so a
broken engine fails in seconds.

## What belongs here

Only **testable pure logic** — no AVFoundation render objects, no security-scoped
URL plumbing, no SwiftUI. The dividing line, per the steering docs, is "factor the
pure math out of AVFoundation-heavy methods and test that directly." Foundation,
CoreMedia (`CMTime`), CoreGraphics value types, and VideoToolbox capability probes
are fine; live `AVAsset`/`AVPlayer`/`CIContext` glue stays in the app target.

## Module layout

```
Sources/LocalCutCore/
  Capabilities/      ← capability-tier decisions (VideoToolbox probe)
  Models/            ← pure value types: Clip, Track, CaptionTrack, ProjectDocument, etc.
  Keyframes/         ← Keyframe<T>, Keyframed<T>, Interpolatable
  Transitions/       ← TransitionLayout geometry (cuts, overlaps, ripple, placements)
  RenderPlanning/    ← VisibleSegment, PlannedUnit, planUnits(), fitTransform()
  TimeFormatting/    ← TimeFormatting.timecode()
  Diagnostics/       ← DiagnosticsBridge (thread-safe ring buffer)
Tests/LocalCutCoreTests/
```

## Fast test coverage

`LocalCutCoreTests` covers the migrated pure-engine seams that should fail fast in
CI: capability-tier decisions, keyframe interpolation, transition ripple
geometry, render planning, time formatting, and Codable project snapshots.

## Migration status

| Module | Status | Notes |
| --- | --- | --- |
| Capabilities | ✅ migrated | Zero project dependencies (Foundation + VideoToolbox only). |
| Models (Clip/Track/ColourGrade/captions/keyframes/audio/WorkingColourSpace) | ✅ migrated | Pure value types + `@Observable` Track/CaptionTrack. |
| TransitionLayout | ✅ migrated | Pure geometry; depends on Clip/Track from Models. |
| Document types (ProjectDocument/MediaRef/TrackDoc/ClipDoc/CMTimeCode) | ✅ migrated | Codable persistence layer. |
| CaptionImporter | ✅ migrated | Pure SRT/VTT parse logic. |
| CaptionPresets | ✅ migrated | Built-in preset library + `.lccaption` I/O. |
| RenderPlanning | ✅ migrated | VisibleSegment, PlannedUnit, planUnits, fitTransform, subRampVolumes. |
| TimeFormatting | ✅ migrated | timecode() display formatter. |
| DiagnosticsBridge | ✅ migrated | Thread-safe ring buffer (OSAllocatedUnfairLock). |

### What stays in the app target

- `MediaItem` — `AVURLAsset` / `AVAssetImageGenerator` (AVFoundation)
- `Project` — references `MediaItem` (AVFoundation dependency)
- `EditorModel` — `@Observable @MainActor`, AVPlayer, undo, security-scoped URLs
- `CompositionBuilder` — `AVMutableComposition` / `AVVideoComposition`
- `EffectCompositor` — `AVVideoCompositing` (Metal/Core Image)
- `RenderQueue` — `AVAssetExportSession` / `AVAssetWriter`
- `AudioMasterBus` — `AVAudioEngine`
- `DiagnosticsAgent` — `proc_pidinfo`, Timer
- All SwiftUI views
