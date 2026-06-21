# Requirements: Phase 1 — Foundation

## R1 — Project scaffolding

- **R1.1** macOS-only SwiftUI app (`SUPPORTED_PLATFORMS = macosx`), target macOS 26, product name "LocalCut Studio".
- **R1.2** Single-window three-pane workspace (media bin · preview · inspector) over a full-width timeline.
- **R1.3** App Sandbox on; user-selected files read-write so exports can be written.

## R2 — Media import

- **R2.1** Import video/audio via `.fileImporter` with multi-select, behind security-scoped access.
- **R2.2** Load metadata asynchronously: duration, natural size, preferred transform, has-video/has-audio.
- **R2.3** Generate a poster thumbnail per video item for the bin.
- **R2.4** Errors surface to a status line; a failed import does not crash or silently vanish.

## R3 — Timeline model & editing

- **R3.1** Multi-track model: `MediaItem`, `Clip` (source range + timeline start + opacity), `Track` (video/audio), `Project`.
- **R3.2** Add a media item to the timeline (ripple-append) onto the first video and/or audio track per its content.
- **R3.3** Select a clip; split the selected clip at the playhead; delete the selected clip.
- **R3.4** Adjust per-clip opacity.

## R4 — Composition & preview

- **R4.1** Build an `AVMutableComposition` + `AVMutableVideoComposition` from the project (multi-track layering, aspect-fit transforms, per-clip opacity).
- **R4.2** Drive an `AVPlayer` preview from the build; rebuild on edits, preserving the playhead.
- **R4.3** Transport: play/pause (Space), seek to start, scrub by dragging the ruler; playhead stays synced to the player.
- **R4.4** Project render settings: resolution preset and frame rate; changing them rebuilds.

## R5 — Export

- **R5.1** Export the composition to `.mov` via `AVAssetExportSession` (highest-quality preset) to a user-chosen path.
- **R5.2** Show determinate export progress and a completion/error status.

## R6 — Verification

- **R6.1** `xcodebuild` (Debug, macOS) compiles cleanly.
- **R6.2** The manual integration smoke test passes end-to-end (import → edit → preview → export).
