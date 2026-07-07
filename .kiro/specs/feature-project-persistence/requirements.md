# Requirements: Project Persistence

## R1 — Document model

- **R1.1** The project serializes to a Codable document (`.lcstudio`, a package or JSON) capturing media references, tracks, clips, effects, transitions, and render settings.
- **R1.2** Media is referenced by **security-scoped bookmark**, not raw path, so reopening works under the sandbox after relaunch.
- **R1.3** Opening a document re-resolves bookmarks; missing media is reported and offered for relink, never silently dropped.

## R2 — Document lifecycle

- **R2.1** New / Open / Save / Save As via the standard menu + shortcuts, using SwiftUI's document scene or an explicit document controller.
- **R2.2** Dirty-state tracking and a save prompt on close with unsaved changes.
- **R2.3** The window title reflects the document name and edited state.

## R3 — Undo/redo

- **R3.1** All model mutations (add, split, delete, trim, move, opacity, grade, transition) register undo with `UndoManager`.
- **R3.2** Standard Edit-menu Undo/Redo with labels; Cmd-Z / Shift-Cmd-Z.
- **R3.3** Undoing/redoing rebuilds the preview and preserves a sensible playhead.

## R4 — Safety

- **R4.1** Saving is atomic; a failed save never corrupts the previous file.
- **R4.2** Project schema is versioned with lenient decoding for additive fields, defaults for older documents, and Save As-only handling for decoded newer documents so newer files are not silently overwritten.

## R5 — Verification

- **R5.1** Unit tests: round-trip encode/decode equality; undo/redo restores prior state.
- **R5.2** Smoke test: build a project, save, relaunch, reopen — media resolves and edits are intact.
