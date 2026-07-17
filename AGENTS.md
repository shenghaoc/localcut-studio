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

> **Roadmap order is the target tag in each `design.md`, _not_ the phase number.** Phase
> numbers track the browser-editor's history; the native port ships them in a different
> order. The ML-tier phases (on-device ASR, Vision matting / reframe / beauty, frame
> interpolation, language tools) are **held until macOS 27 leaves beta** so they share one
> OS baseline — lower-numbered phases can therefore sit _behind_ higher-numbered ones.

### Completed

**Editing core** — [Phase 1 Foundation](.kiro/specs/phase-1-foundation/tasks.md) (multi-track timeline, media bin, live `AVPlayer` preview, split/delete/opacity, `.mov` export) · [Timeline trim & drag](.kiro/specs/feature-timeline-trim-and-drag/tasks.md) · [Transitions](.kiro/specs/feature-transitions/tasks.md) · [Keyframe system](.kiro/specs/feature-keyframes/tasks.md) · [Time remapping (Phase 35)](.kiro/specs/phase-35-speed-ramps/tasks.md)

**Effects & grade** — [Colour grading](.kiro/specs/feature-colour-grading/tasks.md) (custom `AVVideoCompositing`, shared preview/export path) · [Colour management + scopes](.kiro/specs/feature-colour-management/tasks.md) · [Title raster path](.kiro/specs/feature-title-raster/tasks.md) · [Skin smoothing (Phase 32a, no ML)](.kiro/specs/phase-32a-skin-smoothing/tasks.md)

**Audio & captions** — [Audio master bus](.kiro/specs/feature-audio-master-bus/tasks.md) · [Caption tracks](.kiro/specs/feature-caption-tracks/tasks.md) · [Animated caption styles (Phase 30, 花字)](.kiro/specs/phase-30-animated-captions/tasks.md) · [Beat tools (Phase 34, 卡点)](.kiro/specs/phase-34-beat-tools/tasks.md)

**Project & infra** — [Project persistence](.kiro/specs/feature-project-persistence/tasks.md) · [Project bundles](.kiro/specs/feature-project-bundles/tasks.md) · [Render cache](.kiro/specs/feature-render-cache/tasks.md) · [Export presets + render queue](.kiro/specs/feature-export-queue/tasks.md) · [Timeline markers](.kiro/specs/feature-markers/tasks.md) · [Capability tiers](.kiro/specs/feature-capability-tiers/tasks.md) · [LocalCutCore package](.kiro/specs/feature-localcutcore-package/tasks.md) · [Diagnostics panel](.kiro/specs/feature-diagnostics/tasks.md)

**Interchange** — [OpenTimelineIO export (Phase 48)](.kiro/specs/phase-48-otio-interchange/tasks.md) (pure-Swift `.otio` serializer + CMX3600 EDL, bundle `project.otio`, committed reference fixtures)

**UI & shell** — [Design-system integration polish](.kiro/specs/feature-design-system-integration/tasks.md) (shared `EditorPanelHeader`, draggable playhead head, inspector posters; system-adaptive chrome + native accent, collapsible inspector rail, HIG menu-bar / Reduce-Motion conformance, Liquid Glass on floating transport/HUD, split-view divider autosave + keyboard-focusable timeline) · [App Intents + Shortcuts integration](.kiro/specs/feature-app-intents/tasks.md)

**Bugfix specs** — [v0.1.0 consolidation](.kiro/specs/bugfix-v0.1.0-consolidation/tasks.md) · [build warnings & Swift 6 modernization](.kiro/specs/bugfix-build-warnings-and-modernization/tasks.md) · [nonisolated unsafe audit follow-up](.kiro/specs/bugfix-nonisolated-unsafe-audit/tasks.md) · [unchecked Sendable audit](.kiro/specs/bugfix-unchecked-sendable-audit/tasks.md) · [CMTimeCode timescale guard](.kiro/specs/bugfix-cmtimecode-timescale/tasks.md) · [FingerprintIndex JSON determinism](.kiro/specs/bugfix-fingerprint-index-determinism/tasks.md) · [implemented-spec polish](.kiro/specs/bugfix-implemented-spec-polish/tasks.md) · [preview placeholder after rebuild](.kiro/specs/bugfix-preview-placeholder-after-rebuild/tasks.md) · [memory leak cache budgets](.kiro/specs/bugfix-memory-leak-investigation/tasks.md) · [CI flaky-test detection](.kiro/specs/bugfix-ci-flaky-test-detection/tasks.md) · [design/logic review follow-up](.kiro/specs/bugfix-design-and-logic-review-fixes/tasks.md)

### Proposed (ready — not blocked)

In ship order. **Phase 36 is next.**

| Tag | Spec | Scope |
| --- | --- | --- |
| v0.1.5 | [Phase 36 — Voice cleanup](.kiro/specs/phase-36-voice-cleanup/tasks.md) | Master-bus denoise/gate, EBU R128 loudness normalisation, limiter — live and offline. |
| v0.1.6 | [Phase 38 — Look packs & overlays](.kiro/specs/phase-38-look-packs/tasks.md) | Film-emulation nodes + JSON look presets; animated overlays (WebP/Lottie/alpha video). |
| v0.1.7 | [Phase 39 — Vertical & platform finishing](.kiro/specs/phase-39-vertical-finishing/tasks.md) | Aspect modes (9:16/1:1/4:5), safe-zone overlays, cover-frame picker, per-platform presets. |
| v0.1.8 | [Phase 41 — Capture engine](.kiro/specs/phase-41-capture-engine/tasks.md) | ScreenCaptureKit + AVCaptureSession, crash-safe fragmented `.mov` per source as separate tracks. |
| v0.1.9 | [Phase 42 — Recorder UX](.kiro/specs/phase-42-recorder-ux/tasks.md) | Countdown, pause/resume, source switching, webcam PiP, floating control strip, retake. |
| v0.1.10 | [Phase 43 — Screencast post pack](.kiro/specs/phase-43-screencast-look/tasks.md) | Zoom & pan keyframe presets, event-log auto-zoom, callout clips, padded-background preset. |
| v0.1.11 | [Phase 44 — Tutorial finishing](.kiro/specs/phase-44-tutorial-finishing/tasks.md) | Silence detection, keystroke overlay, chapter export, screencast caption preset. |
| v0.1.12 | [Phase 45 — Program mode](.kiro/specs/phase-45-program-mode/tasks.md) | Live switchable scenes through the Metal compositor; ISO tracks + replayable layout track. |
| v0.1.13 | [Phase 46 — Replay buffer + live audio chain](.kiro/specs/phase-46-replay-buffer/tasks.md) | Keyframe-aligned ring buffer "save last N seconds"; live monitor inserts. |
| v0.1.14 | [Phase 47 — WHIP publish](.kiro/specs/phase-47-whip-publish/tasks.md) | Standards-compliant WHIP (RFC 9725) client streaming the program feed to a user endpoint. |

### Proposed (blocked on macOS 27 leaving beta — ML tier)

| Tag | Spec | Scope |
| --- | --- | --- |
| v0.2.1 | [Phase 29 — On-device auto captions](.kiro/specs/phase-29-auto-captions/tasks.md) | Apple `Speech` ASR over clip audio → review-before-apply caption proposals. |
| v0.2.2 | [Phase 31 — Portrait matting](.kiro/specs/phase-31-portrait-matting/tasks.md) | `Vision` person segmentation as a per-clip effect, zero-copy through the compositor. |
| v0.2.3 | [Phase 33 — Smart reframe](.kiro/specs/phase-33-smart-reframe/tasks.md) | Subject-aware crop-path keyframes for aspect conversion, with shot-boundary resets. |
| v0.2.4 | [Phase 32b — Landmark beauty](.kiro/specs/phase-32b-landmark-beauty/tasks.md) | `Vision` face-landmark-driven beauty adjustments. |
| v0.2.5 | [Phase 37 — Frame interpolation](.kiro/specs/phase-37-frame-interpolation/tasks.md) | `VTFrameProcessor` optical-flow interpolation for ultra-smooth slow motion. |
| v1.0.0 | [Phase 40 — On-device language tools](.kiro/specs/phase-40-language-tools/tasks.md) | Translation / language features — browser-editor v1 parity. |

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
