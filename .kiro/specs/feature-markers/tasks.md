# Tasks: Timeline Markers

> Status: **Implemented**. Ships alongside the Phase 34 prep.

## Model

- [x] **T1.1** Add `TimelineMarker` to `Models.swift` with the field set in
  the [design](./design.md#model) and explicit `Codable` for the `time` field
  via the project-wide `CMTimeCode` shape (so the document representation
  matches caption lines / keyframes).
- [x] **T1.2** Extend `Project` with `markers: [TimelineMarker]`; document
  that `Project.duration` is unaffected by markers.

## Persistence

- [x] **T2.1** Add `markers` to `ProjectDocument`; lenient decoding so legacy
  documents without the field decode to `[]`.
- [x] **T2.2** Bump `ProjectDocument.currentSchemaVersion` from 2 to 3.
- [x] **T2.3** Extend `ProjectState` (the undo snapshot) with the marker
  array; capture in `captureState`, restore in `applyState`.

## Editing

- [x] **T3.1** `EditorModel+Markers.swift` extension: `addMarkerAtPlayhead`,
  `removeMarker`, `renameMarker` through `performUndoable`; a coalesced
  variant for name typing through `performCoalescedUndoable` keyed on the
  marker id.
- [x] **T3.2** `selectedMarkerID` on `EditorModel`; restored by `applyState`
  so undo/redo keeps the user's focus.

## UI

- [x] **T4.1** Ruler glyphs in `TimelineView.swift`: diamond + label, accent
  fallback colour, selected-state stroke.
- [x] **T4.2** Hit-testing: tapping a marker glyph selects it; tapping the
  ruler away from a glyph clears the selection.
- [x] **T4.3** Keyboard: `M` adds, `Shift+M` opens the rename popover,
  `Shift+M` reports a status-line hint when no marker is selected, and
  `Delete` removes the selected marker without disturbing the existing clip /
  transition delete shortcut.
- [x] **T4.4** `MarkersInspectorView` section listing markers with
  click-to-seek timecode, in-place rename field, and a delete button.

## Verification

- [x] **T5.1** Unit test: insert preserves sorted-by-time order.
- [x] **T5.2** Unit test: `ProjectDocument` round-trip preserves markers
  losslessly, including the optional `colour`.
- [x] **T5.3** Unit test: legacy document without `markers` decodes to empty.
- [x] **T5.4** Unit test: delete-then-undo restores a marker with its
  original UUID; a typing burst on the name coalesces to one undo step.
- [x] **T5.5** `xcodebuild` (Debug, macOS) green; no test count regression.
