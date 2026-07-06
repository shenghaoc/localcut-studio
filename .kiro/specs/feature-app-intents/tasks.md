# Tasks: App Intents + Shortcuts Integration

> Status: **Implemented** on this branch.

## App shell and dependency wiring

- [x] **T1.1** Add `LocalCutAppIntentRouter` and the four App Intent entry points in `LocalCut Studio/AppIntents.swift`.
- [x] **T1.2** Register the router through `AppDependencyManager` from `LocalCutStudioApp.init()`.
- [x] **T1.3** Keep the router and main window on the same app-scoped `EditorModel` via `LocalCutStudioAppState`.

## Command routing

- [x] **T2.1** Route New Project, Import Media, Export Project, and Show Diagnostics through existing editor/model commands.
- [x] **T2.2** Serialize concurrent actions inside the router so system-triggered commands do not overlap.
- [x] **T2.3** Preserve distinct router error types for empty timeline, action cancellation, panel cancellation, and command failure.

## Command-outcome propagation

- [x] **T3.1** Return `EditorCommandOutcome` from import/export command paths used by App Intents.
- [x] **T3.2** Preserve concrete `statusMessage` text when import/export fails after the user confirmed the action.
- [x] **T3.3** Reject false-success export flows when render queue enqueue fails synchronously.
- [x] **T3.4** Reject false-success import flows when all selected media fail to import.

## Export destination persistence

- [x] **T4.1** Store export queue access as a destination-folder bookmark plus `outputDisplayName`, not a bookmark to a non-existent new file.
- [x] **T4.2** Continue resolving older file-backed bookmarks for reveal, retry, and queued execution.

## Verification

- [x] **V1** Add `AppIntentsTests.swift` coverage for shortcut parity, supported modes, diagnostics routing, empty timeline export, router error mapping, serialization, cancellation, and import/export failure propagation.
- [x] **V2** Add `ExportQueueTests` coverage for resolving folder-backed output destinations.
- [x] **V3** Keep local `xcodebuild` validation green for the App Intents suite and the full macOS scheme before merge.
