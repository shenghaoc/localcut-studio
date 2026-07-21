# Design: App Intents + Shortcuts Integration

> **Ownership note:** App Intent cold-launch readiness, editor-window routing,
> and exact-file render destination grants are now owned by
> [`feature-native-document-lifecycle`](../feature-native-document-lifecycle/design.md).
> That design supersedes the earlier readiness and destination-folder models
> retained in this historical feature spec.


> Status: **Implemented** on PR #54.

## Goal

Expose a small, high-value App Intents surface for LocalCut Studio that works with the current
desktop architecture instead of adding a parallel command stack. The system entry points should open
the app in the foreground, reuse the same document prompts and panels as the menu bar, and report
the same user-visible status when an action is blocked, cancelled, or fails.

## Architecture

### App-scoped dependency

`LocalCutStudioAppState` owns the single `EditorModel` and a matching `LocalCutAppIntentRouter`.
`LocalCutStudioApp.init()` registers that router with `AppDependencyManager`, so App Intents resolve
the same live editor session the window uses even if SwiftUI recreates the `App` value.

This replaces the earlier "connect later from the first window appearance" dependency wiring.
The router no longer depends on a view callback to find the process-wide model, but each action
still waits for `ActiveEditorRegistry` to report a ready editor window and remains pinned to that
window generation.

### Thin router, existing commands

`LocalCutAppIntentRouter` is a small MainActor bridge in `AppIntents.swift`. It does three things:

1. maps each intent to an existing editor command,
2. serializes concurrent invocations through an actor-backed barrier, and
3. translates `EditorCommandOutcome` into intent-facing errors.

The router does not own document logic, panel presentation, export validation, or diagnostics state.
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

Queued exports reserve the exact `NSSavePanel` output file, persist that file's security-scoped
bookmark, and replace the empty reservation when rendering begins. This preserves the user's file
grant across retries and relaunches. Directory-bookmark jobs from the original implementation remain
supported as a backward-compatibility shape.

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
