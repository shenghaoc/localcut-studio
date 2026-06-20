# Repository Structure

```
Untitled Project/                  ← repo root (git)
├── AGENTS.md  CLAUDE.md  GEMINI.md ← AI router (canonical + redirects)
├── README.md  LICENSE
├── A11Y-CHECKLIST.md  RELEASE-READINESS.md  BLOCKER-CLASSIFICATION.md
├── .github/                       ← CI, dependabot, PR template
├── .kiro/                         ← steering, specs, skills, settings (project intelligence)
├── .jules/                        ← agent learning journals (bolt/palette/sentinel)
├── docs/                          ← user-facing documentation
├── LocalCut Studio.xcodeproj/     ← Xcode project (target: "LocalCut Studio")
└── LocalCut Studio/               ← Swift sources
    ├── ContentView.swift          ← @main app entry + EditorView shell
    ├── Models.swift               ← MediaItem, Clip, Track, Project
    ├── EditorModel.swift          ← @Observable @MainActor orchestrator
    ├── CompositionBuilder.swift   ← Project → AVComposition + AVVideoComposition
    ├── PreviewView.swift          ← AVPlayerView wrapper + transport
    ├── MediaBinView.swift         ← media library panel
    ├── TimelineView.swift         ← ruler, lanes, clips, playhead, zoom
    └── InspectorView.swift        ← selection + project settings
```

## Naming conventions

| Kind | Convention |
|------|-----------|
| Types | `PascalCase` (`EditorModel`, `CompositionBuilder`) |
| Properties / methods | `camelCase` |
| SwiftUI views | `XxxView.swift`, one primary `View` per file |
| Engine types | noun for data (`BuiltComposition`), verb-y `enum` namespaces for stateless builders (`CompositionBuilder`) |
| Constants | `camelCase` for derived config; `SCREAMING_SNAKE` only for true compile-time constants |

## Placement rules

- **No AVFoundation in views** beyond the wrapped `AVPlayerView`; views talk to `EditorModel`.
- **No SwiftUI in the engine** (`CompositionBuilder`, future compositor/exporter).
- One `View` concern per file; lift shared helpers (e.g. `TimeFormatting`) next to their primary user.
- New media-engine code goes in its own file under `LocalCut Studio/` (e.g. `Exporter.swift`, `EffectCompositor.swift`), added to the `LocalCut Studio` target.

## Where things live

| Concern | Location |
|---------|----------|
| Timeline/model mutations | `EditorModel.swift` (+ `Models.swift` types) |
| Composition / transforms | `CompositionBuilder.swift` |
| Playback transport | `EditorModel` + `PreviewView` |
| Export | `EditorModel.export` (later: `Exporter.swift`) |
| UI layout | `*View.swift` |
