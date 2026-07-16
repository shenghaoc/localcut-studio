# Product

## Register

Product decisions lead implementation and visual design. This file is the
register for the users, purpose, principles, and accessibility promises that
feature specs and `DESIGN.md` must preserve.

## Users

Mid-tier creators — YouTube producers, short-documentary editors, corporate-training makers — who need cuts, clip reordering, transitions, colour correction, text overlays, and multi-track audio mixing. They work on a Mac, they know their way around a timeline, and they don't want a subscription editor. Their context: sitting at a desk, focused on their content, wanting the tool to stay out of the way.

## Product Purpose

LocalCut Studio is a native macOS non-linear video editor (NLE). It is the desktop-native sibling of the browser-based [LocalCut Studio](https://github.com/shenghaoc/browser-editor) — the same product goals, realized with Apple frameworks (AVFoundation, Metal, Core Image) instead of browser APIs. Media compute runs entirely on the user's Mac; there is no server-side processing.

Success means a creator can import media, build a timeline, apply effects, and export a high-quality file — all with fluid preview, responsive editing, and no silent failures.

## Brand Personality

**Precise, fast, understated.** The tool gets out of the way. It doesn't shout, doesn't decorate, doesn't try to look like a web app. It feels like a native Mac tool that has been there for years — confident in its purpose, never in the user's face.

Reference: **TeXShop** — minimalist, native, utilitarian. The editor is a workspace, not a brand experience. Every pixel serves the content.

## Anti-references

- **Final Cut Pro** — the magnetic-timeline paradigm and glossy, consumer-leaning aesthetic. LocalCut Studio uses a traditional track-based timeline and a quieter visual language.
- **Kdenlive** — cluttered multi-track interface with too many panels, icons, and visual noise competing for attention. The editor should feel calm and focused, not overwhelming.

Broadly: no template-driven UIs, no panel overload, no reskinning macOS to look like a cross-platform web app.

## Design Principles

1. **Performance is the product** — preview must stay fluid and scrubbable. Use the hardware decoders/encoders (VideoToolbox), Metal/Core Image, and AVFoundation's composition pipeline rather than reinventing them.

2. **Get out of the way** — the most important thing on screen is the user's content. Chrome is minimal; every control earns its place. The editor recedes so the work can advance.

3. **Native by default** — respect macOS conventions: menus, keyboard shortcuts, the file system, sandbox, VoiceOver, Dynamic Type, and accessibility appearance settings. The editing chrome deliberately stays dark for colour-critical work; within that choice, semantic system colours and increased-contrast settings remain authoritative.

4. **Honest state** — long operations (import, thumbnailing, export) report progress and surface errors to the user. Nothing fails silently. A single status line communicates background work and errors.

5. **One render path** — preview and export produce the same image. Effects belong in the shared composition/compositor, never bolted onto only one path. Divergence between what you see and what you export is unacceptable.

## Accessibility & Inclusion

- Apple accessibility guidelines for native macOS apps.
- VoiceOver: every icon-only control has a human-readable `accessibilityLabel`; clip blocks and selectable controls expose meaningful labels with selection state.
- Keyboard: all primary actions have shortcuts (Space for play/pause, Delete for remove clip). No action is mouse-only. Focus is visible; no focus traps.
- Dynamic Type: text uses system text styles so it scales; layouts reflow rather than truncate at large sizes.
- Contrast: meet contrast ratios in the forced-dark editor and with Increase Contrast enabled. Don't rely on colour alone to convey state — pair colour with shape or label.
- Motion: respect Reduce Motion for any animated affordances.
