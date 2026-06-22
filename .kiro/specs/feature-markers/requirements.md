# Requirements: Timeline Markers

## R1 — Model

- **R1.1** A `TimelineMarker` value type carries `id: UUID`, `time: CMTime`,
  `name: String`, and an optional `colour: RGBAColour`.
- **R1.2** `TimelineMarker` is `Hashable`, `Codable`, `Identifiable`, and `Sendable`.
- **R1.3** `Project` holds a `markers: [TimelineMarker]` array kept sorted by
  `time`; every mutation path on `EditorModel` preserves the invariant.
- **R1.4** `Project.duration` is unchanged by markers; an annotation past the
  last clip neither extends nor shortens the playable timeline.

## R2 — Persistence

- **R2.1** `ProjectDocument` round-trips the marker array losslessly via
  `CMTimeCode` for the `time` field.
- **R2.2** `ProjectDocument.currentSchemaVersion` is `3`. A v3 document
  decoded by an older build still loads (lenient decoding), and a v3 document
  decoded by a newer-still build keeps working (the existing newer-schema
  guard already adopts a fresh `documentURL` so a save downconverts visibly).
- **R2.3** A legacy document without `markers` decodes to an empty array.

## R3 — Editing

- **R3.1** Adding, deleting, and renaming a marker each register exactly one
  undo step through `performUndoable`; rename burst-typing folds into one step
  via `performCoalescedUndoable` keyed on the marker id.
- **R3.2** `applyState` restores markers (including their original UUIDs) so a
  redo brings them back with the same identity any earlier command captured.
- **R3.3** `applyState` restores `selectedMarkerID` so undo/redo keeps the
  user's focus.

## R4 — UI

- **R4.1** Markers draw on the timeline ruler as a glyph + label at
  `time * pixelsPerSecond`, using the marker's `colour` when set, the accent
  fallback when not, and a selected-state stroke when `selectedMarkerID`
  matches.
- **R4.2** Tapping a marker glyph selects it; tapping the ruler away from any
  glyph clears the selection.
- **R4.3** `M` adds a marker at the playhead's current time.
- **R4.4** `Shift+M` opens a rename popover anchored to the selected marker;
  submitting commits a `Rename Marker` undo step. If no marker is selected,
  the editor sets `statusMessage` to tell the user to select a marker on the
  ruler first.
- **R4.5** `Delete`, when a marker is selected, removes it. The existing
  clip / transition `Delete` behaviour is unchanged when no marker is selected.
- **R4.6** The Inspector grows a Markers section listing every marker sorted
  by time, with click-to-seek timecode, an in-place rename field, and a
  delete button per row.

## R5 — Verification

- **R5.1** Unit tests: marker insertion preserves sorted-by-time order across
  out-of-order inserts and an exact-time duplicate.
- **R5.2** Unit tests: `ProjectDocument` round-trip preserves the marker
  array losslessly, including the optional `colour`.
- **R5.3** Unit tests: a legacy document without `markers` decodes to an
  empty array.
- **R5.4** Unit tests: deleting a marker then undoing restores it (with its
  original UUID); a typing burst on the marker name folds into one undo step.
- **R5.5** `xcodebuild` (Debug, macOS) green; no test count regression.
