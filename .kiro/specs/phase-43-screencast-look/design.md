# Design: Phase 43 — Screencast Post Pack

> Status: **Proposed**. Target tag: **v0.1.10**.

## Goal

Four screencast-finishing tools: (a) zoom-n-pan presets emitting editable transform keyframes; (b) a DOM-style event log for own-app recordings driving auto-zoom proposals; (c) callout clips (arrow, box, step number, spotlight, blur-region); (d) a padded-background compositor preset.

## Prerequisites

- Phase 41 capture engine (for the cursor event log on own-app capture).
- Keyframes (not yet specced) — zoom-n-pan presets stamp `[Keyframe<CGAffineTransform>]` onto the clip's transform.
- Title raster path (shared with Phase 30) for arrow / box / step / spotlight visuals.

## Approach

1. **Zoom-n-pan presets.** A library of canned curves (slow zoom-in to a region, ken-burns pan, snap-zoom-on-click). Each emits a set of Phase-15 keyframes on the clip's `transform: CGAffineTransform`. Bounded acceleration + velocity caps prevent whip-pan. The keyframes are then editable in the inspector.
2. **Own-app event log.** When recording is targeted at LocalCut Studio itself (own-process, detectable), we install `NSEvent.addLocalMonitorForEvents(matching:handler:)` for the session that logs `(time: CMTime, kind: enum { mouseDown, mouseUp, scroll, key }, position: CGPoint)` to a sidecar `events.json` next to the recording. Local monitors see only events delivered to our own app and do NOT need Accessibility permission — that's the deliberate restriction we want. Cross-application cursor tracking would require a `CGEventTap` with Accessibility permission, which is out of scope.
3. **Auto-zoom proposals.** A panel reads the event log, clusters click bursts, and proposes zoom-n-pan keyframes around each cluster. The user applies / skips per proposal; nothing auto-applies.
4. **Callout clips.** Arrow / box / step-number / spotlight as title-raster overlays composited in the existing pipeline. Blur-region is a CIKernel applied to the region under a P15-keyframable transform.
5. **Padded-background preset.** A whole-canvas composite preset: a configurable background (gradient or wallpaper image) renders behind the clip; the clip is inset with rounded corners and drop shadow. Implemented as a layer-group preset over the existing compositor.
6. **Cursor coordinates on arbitrary screen capture.** Documented as not-possible: on a captured display the cursor is baked into pixels and no system API exposes cursor coordinates for arbitrary apps. Cursor-aware features therefore exist only on the own-app event-log path. A GPU template-match cursor tracker is mentioned as a future experimental flag, with the fragility (cursor-theme variants, DPI scaling) called out.

## Trade-offs

- Auto-zoom proposals reviewed before apply (the same review-before-apply pattern used for Phase 44 silence detection) — keeps the user in control.
- Title-raster callouts vs. custom Metal callouts: the raster path is enough at typical screencast resolutions and reuses existing infra.

## Risks

- Event-tap installation can prompt for accessibility permissions on macOS; we use the own-process API where possible to avoid that prompt entirely.
- Padded-background composites at 4K can be memory-heavy when the background image is large; we downsample the background to the project canvas at preset apply time.

## Non-goals

- OS-level keystroke capture.
- Cross-application cursor effects.
- Anything that requires Accessibility permissions outside the own-process path.
