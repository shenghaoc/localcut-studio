# LocalCut domain, Apple media core, and macOS platform

This package deliberately contains three targets:

- **LocalCutDomain** — Foundation-only domain policy and algorithms. It builds
  and tests on macOS and Linux.
- **LocalCutCore** — Apple media models and algorithms that legitimately use
  CoreMedia, CoreGraphics, CoreVideo, Accelerate, VideoToolbox, Observation,
  and `os`, but never SwiftUI, AppKit, AVKit, or AVFoundation.
- **LocalCutPlatform** — macOS-only, presentation-independent adapters for
  AVFoundation, ScreenCaptureKit, WebRTC, Lottie, capture, publishing, audio,
  and animated-overlay decoding. It never imports SwiftUI or the app module.

The macOS fast loop builds the binary-backed platform target, then runs the
deterministic Domain/Core tests:

```sh
swift build --package-path Packages/LocalCutCore --target LocalCutPlatform
swift test --package-path Packages/LocalCutCore
```

CI also runs the same command on Linux; the package manifest exposes
only `LocalCutDomain` on non-macOS hosts. This makes the portable boundary an
executable constraint rather than a naming convention.

## What belongs here

Cross-platform code belongs in `LocalCutDomain` and may import Foundation only.
Code that uses deterministic Apple media/runtime types belongs in
`LocalCutCore`. Reusable live-framework adapters belong in `LocalCutPlatform`.
The app target owns orchestration and presentation. CI enforces all boundaries with
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
Sources/LocalCutPlatform/
  Audio/             ← AVFoundation voice-cleanup adapters
  Capture/           ← ScreenCaptureKit/AVCapture sessions and writers
  Media/             ← frame scaling and AVFoundation mappings
  Overlays/          ← Lottie/animated-image/alpha-video frame sources
  Publishing/        ← WHIP client, WebRTC bridges, reconnect policy
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
- `AudioMasterBus` — app-owned graph/orchestration consuming platform DSP adapters
- `DiagnosticsAgent` — `proc_pidinfo`, Timer
- All SwiftUI views
