> **Note for AI Agents:** Please read [`AGENTS.md`](AGENTS.md) before proposing or making changes. The current invariant is client-compute-on-the-Mac: AVFoundation/Metal/Core Image do the media work, preview and export share one render path, and there is no server pipeline.

# LocalCut Studio (macOS)

A **native macOS** non-linear video editor — the desktop-native port of the browser-based [LocalCut Studio](https://github.com/shenghaoc/browser-editor). Same product goals (fast import, fluid preview, confident timeline editing, reliable export), realized with Apple frameworks instead of browser APIs. All media compute runs on the user's Mac; nothing is processed server-side.

## Stack

- Swift 6 + SwiftUI + the Observation framework (no Combine)
- AVFoundation composition pipeline (`AVMutableComposition` + `AVMutableVideoComposition`)
- Core Image / Metal for effects (custom `AVVideoCompositing`, upcoming)
- AVKit `AVPlayerView` preview; `AVAssetExportSession` export
- Target: macOS 26, App Sandbox on; Xcode target **LocalCut Studio**

## How it maps from the browser original

| Browser-editor | Native macOS |
|---|---|
| WebCodecs / Mediabunny | AVFoundation / VideoToolbox |
| WebGPU preview | Metal / Core Image |
| Multi-track compositing | `AVMutableComposition` + `AVMutableVideoComposition` |
| Export (H.264/VP9/AV1) | `AVAssetExportSession` / `AVAssetWriter` |
| SolidJS UI | SwiftUI |

## Kiro workflow and repository docs

This repo uses Kiro steering, specs, and skills. Canonical project intelligence lives in `.kiro/`:

- [`.kiro/steering/`](.kiro/steering/) — product, architecture, tech constraints, structure, UI standards, code style, testing, accessibility, security, review policy
- [`.kiro/specs/`](.kiro/specs/) — Requirements → Design → Tasks per phase/feature
- [`.kiro/skills/`](.kiro/skills/) — reusable agent skill packs (`swiftui-patterns`, `avfoundation-pipeline`)
- [`.kiro/settings/mcp.json`](.kiro/settings/mcp.json) — workspace MCP configuration

Top-level Markdown: [`AGENTS.md`](AGENTS.md) is canonical; [`CLAUDE.md`](CLAUDE.md) and [`GEMINI.md`](GEMINI.md) redirect to it. User-facing docs are in [`docs/`](docs/).

## Status — v0.1.0 (foundation)

**Completed** — [Phase 1: Foundation](.kiro/specs/phase-1-foundation/tasks.md): media import, multi-track timeline (ruler/playhead/zoom), live `AVPlayer` preview from the composition, clip split/delete, per-clip opacity, resolution/fps settings, and `.mov` export with progress.

**Proposed / active:**

- [Colour grading](.kiro/specs/feature-colour-grading/tasks.md) — Core Image/Metal effect chain via a custom compositor.
- [Timeline trim & drag](.kiro/specs/feature-timeline-trim-and-drag/tasks.md) — direct-manipulation editing with snapping.
- [Transitions](.kiro/specs/feature-transitions/tasks.md) — cross-dissolve and wipe.
- [Project persistence](.kiro/specs/feature-project-persistence/tasks.md) — Codable document, bookmarks, undo/redo.

## Build & run

Open `LocalCut Studio.xcodeproj` in Xcode 26, select the **LocalCut Studio** scheme and **My Mac**, and Run. Or:

```sh
xcodebuild build -project "LocalCut Studio.xcodeproj" -scheme "LocalCut Studio" -destination 'platform=macOS'
```

## License

[MIT](LICENSE) © 2026 shenghaoc
