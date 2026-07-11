# LocalCut domain and Apple media cores

This package deliberately contains two targets:

- **LocalCutDomain** — Foundation-only domain policy and algorithms. It builds
  and tests on macOS and Linux.
- **LocalCutCore** — Apple media models and algorithms that legitimately use
  CoreMedia, CoreGraphics, CoreVideo, Accelerate, VideoToolbox, Observation,
  and `os`, but never SwiftUI, AppKit, AVKit, or AVFoundation.

The macOS fast loop runs both targets:

```sh
swift test --package-path Packages/LocalCutCore
```

CI also runs the same command on Linux; the package manifest exposes
only `LocalCutDomain` on non-macOS hosts. This makes the portable boundary an
executable constraint rather than a naming convention.

## What belongs here

Cross-platform code belongs in `LocalCutDomain` and may import Foundation only.
Code that uses Apple media/runtime frameworks belongs in `LocalCutCore`, even
when it has no UI. Framework adapters and live `AVAsset`/`AVPlayer`/`CIContext`
glue stay in the app target. CI enforces both boundaries with
`Scripts/validate-layer-boundaries.sh`.

## Module layout

```
Sources/LocalCutDomain/
  Capabilities/      ← pure capability-tier policy
  Capture/           ← platform-neutral EncoderBudget actor
  TimeFormatting/    ← TimeFormatting.timecode()
Sources/LocalCutCore/
  Capabilities/      ← macOS sysctl + VideoToolbox capability probe
  Models/            ← pure value types: Clip, Track, CaptionTrack, ProjectDocument, etc.
  Keyframes/         ← Keyframe<T>, Keyframed<T>, Interpolatable
  Transitions/       ← TransitionLayout geometry (cuts, overlaps, ripple, placements)
  RenderPlanning/    ← VisibleSegment, PlannedUnit, planUnits(), fitTransform()
  Diagnostics/       ← DiagnosticsBridge (thread-safe ring buffer)
Tests/LocalCutDomainTests/
Tests/LocalCutCoreTests/
```

## Fast test coverage

`LocalCutDomainTests` covers portable capability policy, encoder budgeting, and
time formatting. `LocalCutCoreTests` covers Apple media-domain seams including
keyframe interpolation, transition geometry, render planning, and Codable
project snapshots.

## Migration status

| Module | Status | Notes |
| --- | --- | --- |
| Capabilities policy | ✅ LocalCutDomain | Pure value/decision layer; Linux tested. |
| Capability probe | ✅ LocalCutCore | macOS sysctl + VideoToolbox adapter. |
| EncoderBudget | ✅ LocalCutDomain | Explicit capacity supplied by the platform layer. |
| Models (Clip/Track/ColourGrade/captions/keyframes/audio/WorkingColourSpace) | ✅ migrated | Pure value types + `@Observable` Track/CaptionTrack. |
| TransitionLayout | ✅ migrated | Pure geometry; depends on Clip/Track from Models. |
| Document types (ProjectDocument/MediaRef/TrackDoc/ClipDoc/CMTimeCode) | ✅ migrated | Codable persistence layer. |
| CaptionImporter | ✅ migrated | Pure SRT/VTT parse logic. |
| CaptionPresets | ✅ migrated | Built-in preset library + `.lccaption` I/O. |
| RenderPlanning | ✅ migrated | VisibleSegment, PlannedUnit, planUnits, fitTransform, subRampVolumes. |
| TimeFormatting | ✅ LocalCutDomain | Cross-platform timecode formatter. |
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
