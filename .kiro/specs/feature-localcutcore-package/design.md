# Design: LocalCutCore Swift Package

> Status: **Implemented**. Infrastructure prerequisite for fast iteration,
> CI gating, and future EditorModel decomposition.

## Goal

Extract pure, testable engine logic from the Xcode app target into a local
SwiftPM package (`Packages/LocalCutCore`) so it builds and tests without
SwiftUI/AppKit and without the app's `@Observable` orchestration. The payoff
is a fast iteration loop:

```sh
swift test --package-path Packages/LocalCutCore   # ~0.08s
```

CI runs this as a gating job *before* the expensive `xcodebuild` test run, so
a broken engine fails in seconds rather than minutes.

## Architecture

### What belongs in the package

Only **testable pure logic** — no AVFoundation render objects, no
security-scoped URL plumbing, no SwiftUI. The dividing line, per the steering
docs, is "factor the pure math out of AVFoundation-heavy methods and test that
directly." Foundation, CoreMedia (`CMTime`), CoreGraphics value types, and
VideoToolbox capability probes are fine; live `AVAsset`/`AVPlayer`/`CIContext`
glue stays in the app target.

### Module layout

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

### Dependency graph

```
LocalCutCore (package)
  ↑ imported by
  LocalCut Studio (app target)
    → MediaItem, Project, EditorModel, CompositionBuilder, EffectCompositor, ...
```

The package has zero dependencies on the app. The app imports the package.
This is a one-way dependency — the package never references app types.

## Design decisions

### Why `@MainActor` on Track/CaptionTrack

`Track` and `CaptionTrack` are `@Observable` classes with mutable stored
properties. In the app, all mutations flow through `EditorModel` on `@MainActor`.
The package declares them `@MainActor` to make this threading contract explicit
and enforceable by the compiler, replacing the previous `@unchecked Sendable`
conformance which asserted thread safety without enforcement.

Pure functions in the package that only need the *data* from these types (e.g.
`TransitionLayout.cuts(videoTracks:)`, `activeCaptionItems(in:midpoint:)`) accept
value-type snapshots (`[[Clip]]`, `[(defaultStyle:lines:isMuted:)]`) instead of
the `@MainActor` classes, so the geometry and planning logic can run off the main
actor.

### Why `Observation` import is explicit

The `@Observable` macro lives in the `Observation` framework. While Foundation
re-exports it in some toolchain configurations, an explicit `import Observation`
ensures the macro resolves reliably in all SwiftPM build contexts.

### Why types don't carry `nonisolated`

In a SwiftPM package, types default to non-isolated (the package doesn't set
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). The `nonisolated` keyword on
enum/struct/func declarations is redundant and was removed after review feedback.

### Why `AudioMeterSnapshot.silent` is a computed property

`static let silent` would capture `ContinuousClock.now` at first access, freezing
`sampledAt` for the process lifetime. `static var silent` returns a fresh instance
with a current timestamp on each access, so callers checking reading freshness
get accurate results.

## Migration strategy

The extraction follows a dependency-island approach:
1. **Capabilities** first — zero project types, Foundation + VideoToolbox only.
2. **Models** (Clip, Track, CaptionTrack, keyframes, colour grade, captions,
   audio, WorkingColourSpace, sanitization extensions) — the core value types.
3. **TransitionLayout** — pure geometry, depends on Clip/Track from Models.
4. **Document types** (ProjectDocument, MediaRef, TrackDoc, ClipDoc, CMTimeCode)
   — Codable persistence layer.
5. **CaptionImporter** — pure SRT/VTT parse logic.
6. **CaptionPresets** — built-in preset library + `.lccaption` I/O.
7. **RenderPlanning** — VisibleSegment, PlannedUnit, planUnits, fitTransform.
8. **DiagnosticsBridge** — thread-safe ring buffer.
9. **TimeFormatting** — timecode() display formatter.

Each module is moved, its symbols are marked `public`, and the app adds
`import LocalCutCore`. The Xcode project wires the package via
`XCLocalSwiftPackageReference` + `XCSwiftPackageProductDependency`.

## Risks

- **Type name collisions.** `Transition` collides with SwiftUI's `Transition`
  protocol. The app uses `LocalCutCore.Transition` to disambiguate where needed.
- **Incremental migration fragility.** Moving types incrementally means the app
  and package both define some types during the transition. Each move must be
  atomic: remove from app, add to package, update all consumers.
- **Test coverage gap.** The package tests currently only cover Capabilities.
  The other modules' tests live in the Xcode test target. Porting representative
  tests to the package would make the CI gating stage genuinely useful.

## Non-goals

- Making `EditorModel` thinner (separate, larger refactor).
- Moving `MediaItem` or `Project` into the package (AVFoundation dependency).
- Moving SwiftUI views into the package.
