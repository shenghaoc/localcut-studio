# Tasks: Project Persistence

> Status: **Implemented**. Shipped in [#6](https://github.com/shenghaoc/localcut-studio/pull/6) (PR title: "Project persistence: Codable document, save/open, relink & undo/redo"). Code lives in `LocalCut Studio/ProjectDocument.swift` and `LocalCut Studio/EditorModel+Persistence.swift`; tests in `LocalCut StudioTests/PersistenceTests.swift` and `LocalCut StudioTests/UndoRedoTests.swift`. Has since carried schema bumps for caption tracks ([#10](https://github.com/shenghaoc/localcut-studio/pull/10), v2) and project bundles ([#20](https://github.com/shenghaoc/localcut-studio/pull/20), v3).

## Document model

- [x] **T1.1** `ProjectDocument` + `MediaRef`/`TrackDoc`/`ClipDoc` Codable types with `schemaVersion` and `CMTime` coding.
- [x] **T1.2** Snapshot `Project` → document and reconstruct document → `Project`.
- [x] **T1.3** Security-scoped bookmark create/resolve for media; relink flow for missing media.
- [x] **T1.4** Unit tests: encode/decode round-trip equality.

## Lifecycle

- [x] **T2.1** Choose `DocumentGroup` vs. custom controller; wire New/Open/Save/Save As + shortcuts.
- [x] **T2.2** Dirty tracking, save-on-close prompt, window title reflects name + edited state.
- [x] **T2.3** Atomic save.

## Undo/redo

- [x] **T3.1** Route all mutations through `UndoManager`-registering helpers with labels.
- [x] **T3.2** Undo/redo apply snapshot + `rebuild()`, preserve playhead.
- [x] **T3.3** Unit tests: undo/redo restores prior state.

## Verification

- [x] **T4.1** Smoke test: build → save → relaunch → reopen; media resolves, edits intact.
- [x] **T4.2** `xcodebuild` green; tests green with no count regression.
