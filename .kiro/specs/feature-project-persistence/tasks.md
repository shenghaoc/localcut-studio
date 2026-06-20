# Tasks: Project Persistence

> Status: **Proposed**.

## Document model

- [ ] **T1.1** `ProjectDocument` + `MediaRef`/`TrackDoc`/`ClipDoc` Codable types with `schemaVersion` and `CMTime` coding.
- [ ] **T1.2** Snapshot `Project` → document and reconstruct document → `Project`.
- [ ] **T1.3** Security-scoped bookmark create/resolve for media; relink flow for missing media.
- [ ] **T1.4** Unit tests: encode/decode round-trip equality.

## Lifecycle

- [ ] **T2.1** Choose `DocumentGroup` vs. custom controller; wire New/Open/Save/Save As + shortcuts.
- [ ] **T2.2** Dirty tracking, save-on-close prompt, window title reflects name + edited state.
- [ ] **T2.3** Atomic save.

## Undo/redo

- [ ] **T3.1** Route all mutations through `UndoManager`-registering helpers with labels.
- [ ] **T3.2** Undo/redo apply snapshot + `rebuild()`, preserve playhead.
- [ ] **T3.3** Unit tests: undo/redo restores prior state.

## Verification

- [ ] **T4.1** Smoke test: build → save → relaunch → reopen; media resolves, edits intact.
- [ ] **T4.2** `xcodebuild` green; tests green with no count regression.
