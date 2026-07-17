# Design: Phase 43 — Screencast Post Pack

> Status: **Implemented**. Target tag: **v0.1.10**.

## Goal

Four screencast-finishing tools: (a) zoom-n-pan presets emitting editable transform keyframes; (b) a DOM-style event log for capture sessions driving auto-zoom proposals; (c) callout clips (arrow, box, step number, spotlight, blur-region); (d) a padded-background compositor preset.

## Prerequisites

- Phase 41 capture engine (for capture-session sidecars).
- Keyframe system — zoom-n-pan presets stamp `[Keyframe<Transform2D>]` into a clip-local `Keyframed<Transform2D>` track.
- Title raster path (shared with Phase 30) for arrow / box / step / spotlight visuals.

## Approach

1. **Zoom-n-pan presets.** A library of canned curves (slow zoom-in to a region, ken-burns pan, snap-zoom-on-click). Each emits clip-source-local `Transform2D` keyframes. Bounded acceleration + velocity caps prevent whip-pan. The keyframes are then editable in the inspector.
2. **Capture event log.** Every screen recording session can create an `events.json` sidecar. When recording LocalCut Studio itself (own-process, detectable), `NSEvent.addLocalMonitorForEvents(matching:handler:)` returns an opaque monitor token; we store it on the recording session and pass it to `NSEvent.removeMonitor(_:)` on pause, stop, source switch, and in the writer's `deinit` (belt-and-braces). Own-app logs may include mouse, scroll, and key-code events. Display, window, and non-own app targets use `NSEvent.addGlobalMonitorForEvents` for mouse and scroll only; this keeps click/scroll-driven auto-zoom available without Accessibility permission and without logging cross-app text or key strokes. Coordinates are normalised to the captured display/window bounds when the event can be matched; non-own application targets are mapped in display coordinate space, and unmatched global events are dropped.
3. **Auto-zoom proposals.** A panel reads a landed capture sidecar or a standalone imported `events.json`, clusters click bursts, and proposes zoom-n-pan keyframes around each cluster. The user applies / skips per proposal; nothing auto-applies.
4. **Callout clips.** Arrow / box / step-number / spotlight as title-raster overlays composited in the existing pipeline. Blur-region is a CIKernel applied to the region under a keyframed `Transform2D`. Stored handles define one temporal Bezier progress curve for all transform components; handle-free tracks use the generic linear interpolation path. Inspector evaluation and the shared preview/export compositor call the same evaluator.
5. **Padded-background preset.** A whole-canvas composite preset: a configurable background (gradient or wallpaper image) renders behind the clip; the clip is inset with rounded corners and drop shadow. Image-backed presets keep the security-scoped bookmark in the model. The renderer creates an ImageIO thumbnail lazily on first use for the requested canvas dimension, then reuses a bounded, memory-pressure-purgeable cache keyed by bookmark and dimension. This keeps decode work out of the main-actor apply action and supports render-queue snapshots at their actual output size.
6. **Cursor coordinates on arbitrary screen capture.** Display and non-own app recordings support click/scroll positions from the global mouse monitor when those events can be mapped into the capture target. Continuous cursor paths and cross-app key/text capture remain out of scope. A GPU template-match cursor tracker is mentioned as a future experimental flag, with the fragility (cursor-theme variants, DPI scaling) called out.

## Trade-offs

- Auto-zoom proposals reviewed before apply (the same review-before-apply pattern used for Phase 44 silence detection) — keeps the user in control.
- Title-raster callouts vs. custom Metal callouts: the raster path is enough at typical screencast resolutions and reuses existing infra.

## Risks

- Event-tap installation can prompt for Accessibility permissions on macOS; the implementation intentionally stays on `NSEvent` local/global monitors and does not install an event tap.
- Padded-background composites at 4K can be memory-heavy when the background image is large; the first render decodes only a canvas-sized thumbnail, and the bounded cache is purgeable under memory pressure.

## Non-goals

- OS-level keystroke or text capture.
- Continuous cross-application cursor tracking.
- Anything that requires Accessibility permissions.
