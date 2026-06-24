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

Target layout (folders added as each module migrates):

```
Sources/LocalCutCore/
  Capabilities/      ← migrated: capability-tier decisions
  Models/            ← planned
  Timeline/          ← planned
  Keyframes/         ← planned
  Transitions/       ← planned
  RenderPlanning/    ← planned
  TimeFormatting/    ← planned
Tests/LocalCutCoreTests/
```

## Migration status

| Module | Status | Notes |
| --- | --- | --- |
| Capabilities | ✅ migrated | Zero project dependencies (Foundation + VideoToolbox only); single app consumer (`DiagnosticsView`). |
| Models (`Clip`/`Track`/`Project`/keyframes/colour grade/captions…) | ⏳ planned | One tightly-coupled component used by nearly every file; migrating it makes the core value types `public` and adds `import LocalCutCore` across the app. |
| TransitionLayout | ⏳ planned | Pure geometry, but depends on `Clip`/`Track` — move with (or after) Models. |
| Render planning / time formatting | ⏳ planned | Factor the pure math out of the AVFoundation builders first. |

### How to migrate the next module

1. Pick a dependency *island* — code whose only project dependencies are types
   already in the package (or none). Move the source file under the matching
   `Sources/LocalCutCore/<Area>/` folder.
2. Mark the symbols the app consumes `public` (and any `Comparable`/protocol
   witnesses that must match a public requirement).
3. Add `import LocalCutCore` to every app/test file that referenced those symbols.
4. Move the corresponding test file into `Tests/LocalCutCoreTests/` and switch its
   `@testable import LocalCut_Studio` to `import LocalCutCore`.
5. Verify both loops: `swift test --package-path Packages/LocalCutCore` **and**
   the Xcode build (`xcodebuild … test`), since the app target now links the
   package product.

Because the app uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` but a SwiftPM
target defaults to non-isolated, keep the explicit `nonisolated` annotations on
moved types so behaviour matches across both build systems.
