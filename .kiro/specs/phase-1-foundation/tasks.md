# Tasks: Phase 1 — Foundation

> Status: **Completed**.

## Scaffolding

- [x] **T1.1** Scope target to macOS (`SUPPORTED_PLATFORMS = macosx`); set product name "LocalCut Studio".
- [x] **T1.2** `ENABLE_USER_SELECTED_FILES = readwrite` for export under sandbox.
- [x] **T1.3** App shell: `LocalCutStudioApp` + `EditorView` (`VSplitView`/`HSplitView`) + toolbar + status bar.

## Model & engine

- [x] **T2.1** `Models.swift` — `MediaItem`, `Clip`, `Track`, `TrackKind`, `Project`.
- [x] **T2.2** `CompositionBuilder.build(project:)` — multi-track insert, audio tracks, duration.
- [x] **T2.3** `fitTransform` — aspect-fit + center honouring `preferredTransform`.
- [x] **T2.4** Non-overlapping instruction segmentation with per-track layer instructions.

## Orchestration

- [x] **T3.1** Async `importMedia(urls:)` with security-scoped access + metadata load.
- [x] **T3.2** Async thumbnail generation per video item.
- [x] **T3.3** `addToTimeline`, `splitSelectedClipAtPlayhead`, `deleteSelectedClip`, `updateSelectedClip`.
- [x] **T3.4** `rebuild()` — replace player item, preserve playhead.
- [x] **T3.5** Transport: periodic time observer, play/pause, seek; end-of-item handling.

## Views

- [x] **T4.1** `MediaBinView` — import, thumbnails, add-to-timeline.
- [x] **T4.2** `PreviewView` — `AVPlayerView` wrapper + transport bar + timecode.
- [x] **T4.3** `TimelineView` — ruler, lanes, clip blocks, playhead, zoom slider.
- [x] **T4.4** `InspectorView` — clip opacity + project resolution/fps.

## Export & verification

- [x] **T5.1** `export(to:)` via `AVAssetExportSession` + `states(updateInterval:)` progress.
- [x] **T5.2** `NSSavePanel` destination; status messages.
- [x] **T6.1** `xcodebuild` Debug/macOS green; app launches and runs the smoke test.
