# Product Purpose

## Vision

A **native macOS** non-linear video editor (NLE) that feels like a first-class desktop editor for common creator projects: fast import, responsive preview, confident timeline editing, and reliable export. It is the desktop-native sibling of the browser-based [LocalCut Studio](https://github.com/shenghaoc/browser-editor) — the same product goals, realized with Apple frameworks instead of browser APIs. Media compute runs on the user's Mac (CPU/GPU via AVFoundation, Metal, VideoToolbox); there is no server-side processing.

## Target Users

Mid-tier creators (YouTube, short documentary, corporate training) who need cuts, clip reordering, transitions, colour correction, text overlays, multi-track audio mixing, and high-quality export — on a Mac, without a subscription editor.

## Key Principles

1. **Performance is the product** — preview must stay fluid and scrubbable; use the hardware decoders/encoders (VideoToolbox), Metal/Core Image, and AVFoundation's composition pipeline rather than reinventing them.
2. **One render path** — preview and export must produce the same image. Effects belong in the shared composition/compositor, never bolted onto only one path.
3. **Native by default** — respect macOS conventions: menus, keyboard shortcuts, the file system, sandbox, VoiceOver, Dynamic Type, light/dark.
4. **Honest state** — long operations (import, thumbnailing, export) report progress and surface errors to the user; nothing fails silently.
5. **Task completion beats purity** — ship the feature that lets a user import, cut, preview, and export successfully; refine the architecture behind a stable surface.

## Non-Goals (v1)

- Accounts, cloud sync, telemetry, or any server-side media processing.
- iOS/iPadOS/visionOS builds — the target is scoped to macOS for now.
- Plugin marketplace, multi-user collaboration, motion-graphics authoring.
- Pretending to support unbounded resolutions/codecs; capability and format limits are stated, not hidden.
