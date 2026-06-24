# AI Agent Quickstart (Kiro Workflow)

Use this file as a **thin router**. Read steering before coding; specs live under `.kiro/specs/`.

LocalCut Studio is a **native macOS port** of the [browser-editor](https://github.com/shenghaoc/browser-editor) (a browser-native NLE also called *LocalCut Studio*). The invariant flips from "client-compute in the browser" to **"client-compute on the Mac"**: AVFoundation/Metal/Core Image do the media work; there is no server pipeline.

## Read steering first

- [**Product vision**](.kiro/steering/product.md) — desktop-native NLE for mid-tier creators; performance is the product.
- [**Architecture**](.kiro/steering/architecture.md) — AVFoundation composition pipeline, preview vs. export paths, development phases.
- [**Technical constraints**](.kiro/steering/tech.md) — Swift 6 + SwiftUI, AVFoundation, Metal/Core Image, Xcode target on macOS 26.
- [**Repository structure**](.kiro/steering/structure.md) — engine vs. views, file naming, layout.
- [**UI standards**](.kiro/steering/ui-standards.md) — native macOS look, bespoke timeline, AppKit interop where needed.
- [**Code style**](.kiro/steering/style.md) — Swift conventions, Observation, concurrency, naming.
- [**Testing standards**](.kiro/steering/testing.md) — Swift Testing scope, what to test, quality gate.
- [**Accessibility**](.kiro/steering/accessibility.md) — VoiceOver, keyboard, Dynamic Type, contrast.
- [**Security & safety**](.kiro/steering/security.md) — App Sandbox, security-scoped files, no secrets, resource lifetimes.
- [**Review policy**](.kiro/steering/review.md) — review process + output format (`#review`); priorities live in [Review guidelines](#review-guidelines) below.

## Workspace MCP config

[`.kiro/settings/mcp.json`](.kiro/settings/mcp.json) — workspace MCP server configuration. Xcode IDE tooling (build, documentation search, code issues) is provided by the host's `xcode-tools` MCP server, not spawned here.

## Skills

Reusable packs in [`.kiro/skills/`](.kiro/skills/):

- **swiftui-patterns** — SwiftUI + Observation conventions for this app (state ownership, `@Observable`, main-actor isolation).
- **avfoundation-pipeline** — composition/video-composition/export conventions and `CMTime`/`AVAsset` lifetimes.

## Specs (`.kiro/specs/`)

Each spec has `design.md`, `requirements.md`, and `tasks.md` (bugfix specs use `bugfix.md` instead of `requirements.md`).

**Completed:**

- [**Phase 1 — Foundation**](.kiro/specs/phase-1-foundation/tasks.md) — multi-track timeline, media bin, live `AVPlayer` preview from `AVMutableComposition`, clip split/delete, per-clip opacity, resolution/fps settings, and `.mov` export with progress.
- [**LocalCutCore package**](.kiro/specs/feature-localcutcore-package/tasks.md) — extract pure engine logic (models, transitions, render planning, keyframes, captions, diagnostics, time formatting) into a local SwiftPM package for fast `swift test` iteration and CI gating.

**Active / Proposed:**

- [**Colour grading**](.kiro/specs/feature-colour-grading/tasks.md) — Core Image / Metal effect chain (exposure, contrast, saturation, white balance, LUT) applied through a custom `AVVideoCompositing` so preview and export share one render path.
- [**Timeline trim & drag**](.kiro/specs/feature-timeline-trim-and-drag/tasks.md) — direct-manipulation trimming of clip edges and drag-to-move within and across tracks, with snapping and ripple options.
- [**Transitions**](.kiro/specs/feature-transitions/tasks.md) — cross-dissolve and wipe transitions between adjacent clips via tween layer instructions / Core Image transition filters.
- [**Project persistence**](.kiro/specs/feature-project-persistence/tasks.md) — Codable document model with security-scoped bookmarks, save/open, and undo/redo.

## Review guidelines

> **Single source of truth.** Every review agent (Claude, Gemini, Kiro, Codex) reads
> **this** checklist. `CLAUDE.md` and `GEMINI.md` redirect here via `@AGENTS.md`;
> [`.kiro/steering/review.md`](.kiro/steering/review.md) adds only process + output format.
> Severity ↔ priority: **critical → P0**, **high → P1** (GitHub surfaces P0/P1).

### Method

1. Read the spec(s) the PR claims to implement; check the diff against the stated tasks.
2. Build with `xcodebuild` (or the Xcode MCP `BuildProject`) and run the test suite before judging behaviour.
3. Reason about concurrency: this target defaults to `MainActor` isolation — flag any blocking work (decode, export, large file IO) left on the main actor.
4. Trace resource lifetimes: `AVAssetImageGenerator`, security-scoped URLs, time observers, `Task`s.

### P0 — blocking

- **Correctness**: wrong composition math (time ranges, transforms), off-by-one on `CMTime`, clips inserted at wrong offsets.
- **Concurrency**: main-actor stalls (synchronous export/decode), data races, unbalanced actor isolation, retained `self` in escaping observers without `[weak self]`.
- **Resource leaks**: security-scoped resource not stopped, periodic time observer not removed, `Task` never cancelled, `AVAssetImageGenerator` retained per-frame.
- **Sandbox/security**: writing outside user-selected locations, secrets in source, force-unwrapping user-supplied media metadata.
- **Data loss**: edits that silently drop clips/tracks; export that overwrites without intent.

### P1 — high

- Silent failure paths (errors swallowed, no user-visible message in `statusMessage`).
- Preview and export diverging (an effect applied in one path but not the other).
- Missing `accessibilityLabel` on icon-only controls; keyboard traps.
- Dead code, unused state, or comments that no longer match the code.
- Unnecessary full-composition rebuilds on every keystroke / slider tick (debounce or diff instead).

### Always

- Tests accompany non-trivial logic; test count must not decrease from the last green run.
- `xcodebuild` (Debug, macOS) must compile cleanly before merge.
