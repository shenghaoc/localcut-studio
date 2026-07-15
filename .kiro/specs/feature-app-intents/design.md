# Design: App Intents + Shortcuts Integration

> Status: **Implemented** on PR #54.

## Goal

Expose a small, high-value App Intents surface for LocalCut Studio that works with the current
desktop architecture instead of adding a parallel command stack. The system entry points should open
the app in the foreground, reuse the same document prompts and panels as the menu bar, and report
the same user-visible status when an action is blocked, cancelled, or fails.

## Architecture

### App-scoped dependency

`LocalCutStudioAppState` owns the router dependency, while
`ActiveDocumentRegistry` owns weak registrations for live editor windows.
`LocalCutStudioApp.init()` registers the router with `AppDependencyManager`, so
App Intents can resolve the key/most-recent editor even if SwiftUI recreates
the `App` value.

This replaces the earlier direct process-wide-model assumption. Before a window
has registered (including cold launch), the router fails with a typed
`noActiveDocument` error instead of guessing a target.

### Thin router, existing commands

`LocalCutAppIntentRouter` is a small MainActor bridge in `AppIntents.swift`. It does three things:

1. maps each intent to an existing editor command,
2. serializes concurrent invocations through an actor-backed barrier, and
3. translates `EditorCommandOutcome` into intent-facing errors.

The router does not own document logic, panel presentation, export validation,
diagnostics state, or an editor model. It captures the active registry token
when an action is received and validates that exact target just before execution,
so a queued action never retargets after a window closes.
Those stay in the existing editor/model layer:

- new project -> `EditorModel.performNewProjectCommand()`
- import media -> `EditorModel.performImportMediaCommand()`
- export project -> `EditorModel.performExportProjectCommand()`
- diagnostics -> existing `isDiagnosticsVisible` toggle

Keeping the intents thin preserves macOS-native behaviour: save prompts, `NSOpenPanel`, `NSSavePanel`,
recording guards, chapter-validation guards, and status copy still come from the same code paths the
menu bar and visible app use.

### Error and cancellation semantics

The router distinguishes three user-facing classes of non-success:

- `actionCancelled` for command-level cancellation without a dismissed picker,
- `panelCancelled` for import/export picker dismissal,
- `actionFailed` for command failures after the user confirmed the flow.

The status bar remains the source of truth for the concrete reason. The intent layer supplies only a
fallback typed error when the command path does not already set one.

### Import/export outcome propagation

The command layer now returns `EditorCommandOutcome` all the way through the App Intents entry
points:

- import returns `.failed` when every selected file fails to load,
- export returns `.failed` when queueing rejects the job synchronously,
- cancellation stays distinct from failure.

This fixes the false-success paths where a shortcut could report success after the underlying command
had already surfaced an error to the user.

### Export destination persistence

Queued exports persist a security-scoped bookmark to the destination folder plus the output filename,
not a bookmark to the non-existent output file itself. That matches `NSSavePanel` for brand-new
files, survives queue retries/relaunches, and still resolves older file-bookmark jobs for backward
compatibility.

## UX / HIG fit

No new custom shell UI is introduced. The feature relies on system App Intents surfaces, immediate
foreground activation, existing document panels, and existing menu-backed editor commands. That keeps
the shortcut flow consistent with the rest of the app's macOS behaviour instead of inventing a
second interaction model.

## Test strategy

Coverage stays focused on the bridge and the command/result edges:

- shortcut list parity with exposed actions,
- immediate foreground supported modes,
- diagnostics routing,
- empty-timeline export error mapping,
- distinct router error types,
- action serialization and cancellation,
- new-project cancellation after confirm-save prompt,
- import/export failure propagation,
- export queue rejection after selecting a brand-new destination path.
- no-active-document, active-editor capture, and closed-token routing behavior
  (added by the native document lifecycle feature).
