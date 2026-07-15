# Tasks: Project Persistence

> Status: **Implemented**. Shipped in [#6](https://github.com/shenghaoc/localcut-studio/pull/6) (PR title: "Project persistence: Codable document, save/open, relink & undo/redo"). Code now lives in `Packages/LocalCutCore/Sources/LocalCutCore/Models/DocumentTypes.swift`, `LocalCut Studio/DocumentController.swift`, and `LocalCut Studio/EditorModel+Persistence.swift`; tests in `LocalCut StudioTests/PersistenceTests.swift` and `LocalCut StudioTests/UndoRedoTests.swift`. Current schema versioning and compatibility behavior are documented in [`docs/PROJECT_SCHEMA.md`](../../../docs/PROJECT_SCHEMA.md).

## Document model

- [x] **T1.1** `ProjectDocument` + `MediaRef`/`TrackDoc`/`ClipDoc` Codable types with `schemaVersion` and `CMTime` coding.
- [x] **T1.2** Snapshot `Project` → document and reconstruct document → `Project`.
- [x] **T1.3** Security-scoped bookmark create/resolve for media; relink flow for missing media.
- [x] **T1.4** Unit tests: encode/decode round-trip equality.
- [x] **T1.5** Maintain `docs/PROJECT_SCHEMA.md` as the current ProjectDocument schema and compatibility reference.

## Lifecycle

- [x] **T2.1** Choose custom controller over `DocumentGroup`/`ReferenceFileDocument`; wire New/Open/Open Recent/Save/Save As + shortcuts. The macOS 26 no-go evidence is recorded in [Native document lifecycle](../feature-native-document-lifecycle/design.md).
- [x] **T2.2** Dirty tracking, async save-on-close prompt, window title reflects name + edited state.
- [x] **T2.3** Atomic save.

## Undo/redo

- [x] **T3.1** Route all mutations through `UndoManager`-registering helpers with labels.
- [x] **T3.2** Undo/redo apply snapshot + `rebuild()`, preserve playhead.
- [x] **T3.3** Unit tests: undo/redo restores prior state.

## Verification

- [x] **T4.1** Smoke test: build → save → relaunch → reopen; media resolves, edits intact.
- [x] **T4.2** `xcodebuild` green; tests green with no count regression.
