# Design: Phase 1 — Foundation

> Status: **Completed** (initial commit).

## Goal

Establish the native editing skeleton: a model-driven `AVComposition` that feeds both preview and export, with a usable three-pane + timeline UI. Prove import → arrange → preview → export end-to-end before adding effects.

## Delivered architecture

- **Model** (`Models.swift`) — `MediaItem` (holds `AVURLAsset` + loaded metadata), `Clip` (`struct`: source range, timeline start, opacity), `Track` (`@Observable`: kind + clips), `Project` (`@Observable`: media, video/audio tracks, render size, fps).
- **Engine** (`CompositionBuilder.swift`) — `build(project:)` inserts each clip into one composition track per project track, computes an aspect-fit `fitTransform`, segments the timeline at clip boundaries into non-overlapping `AVMutableVideoCompositionInstruction`s with per-track layer instructions (topmost first), and returns a `BuiltComposition`.
- **Orchestrator** (`EditorModel.swift`) — `@Observable @MainActor`: async import + thumbnailing, ripple-append, split/delete/opacity, `rebuild()` (replaces the `AVPlayerItem`, preserves playhead), transport (periodic time observer → `currentTime`), and async export with `states(updateInterval:)` progress.
- **Views** — `EditorView` (split layout + toolbar + status), `MediaBinView` (`.fileImporter`, thumbnails), `PreviewView` (`AVPlayerView` wrapper + transport bar), `TimelineView` (Canvas ruler, lanes, clip blocks, draggable playhead, zoom), `InspectorView` (clip + project settings).

## Key decisions

- **One render path**: preview and export both consume `BuiltComposition`; no effect is special-cased to one.
- **Manual layer instructions** (not `applyingCIFiltersWithHandler:`) so genuine multi-track layering with transforms/opacity works from day one.
- **AppKit at the edge only**: `AVPlayerView` wrapped via `NSViewRepresentable`; `NSSavePanel` for export destination.
- **`MainActor` default isolation**: model/views on the main actor; export/asset-loading are `async` and yield.

## Out of scope (later phases)

- Colour grading / effect chain (custom `AVVideoCompositing`).
- Clip trim/drag, transitions, audio waveforms/mixing.
- Project persistence + undo/redo; titles/text; export format/range expansion.
