# Requirements: App Intents + Shortcuts Integration

> Status: **Implemented**.

## R1 — Exposed actions

- **R1.1** The app exposes four App Intents: New Project, Import Media, Export Project, and Show Diagnostics.
- **R1.2** Each exposed shortcut action has exactly one corresponding router action and one App Shortcut entry.
- **R1.3** All four intents run in `.foreground(.immediate)` mode so system invocation opens the app into the existing document workflow.

## R2 — Dependency wiring

- **R2.1** App Intents resolve through `AppDependencyManager`, not a view-lifecycle callback.
- **R2.2** The router resolves the focused or most recently active registered
  editor through `ActiveDocumentRegistry`; it does not retain an `EditorModel`.
- **R2.3** Before any editor scene registers (including cold launch), intent
  routing fails with a clear typed no-active-document error instead of depending
  on a process-wide model.

## R3 — Routing behaviour

- **R3.1** Intents reuse existing editor commands and do not duplicate document, import, export, or diagnostics logic.
- **R3.2** Concurrent intent invocations are serialized so two system-triggered actions cannot mutate the editor concurrently.
- **R3.3** Cancelling a queued action does not leave the router chain stuck behind the cancelled work item.

## R4 — Outcome semantics

- **R4.1** Empty-timeline export surfaces a dedicated error and status message.
- **R4.2** Picker dismissal maps to `panelCancelled`; command-level cancellation without picker dismissal maps to `actionCancelled`.
- **R4.3** Import returns failure when every selected file fails to load.
- **R4.4** Export returns failure when queue enqueue rejects the job before background rendering starts.
- **R4.5** Failure paths preserve the underlying `statusMessage` when the command already supplied user-visible detail.

## R5 — Export destination handling

- **R5.1** Export queue jobs persist access to the selected destination folder plus the chosen filename, so brand-new save destinations are valid.
- **R5.2** Queue resolution continues to support older jobs whose bookmark resolves directly to a file URL.

## R6 — Verification

- **R6.1** `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme "LocalCut Studio" -destination "platform=macOS" -only-testing:"LocalCut StudioTests/AppIntentsTests"` passes.
- **R6.2** App Intents tests cover routing, serialization, cancellation, and import/export failure propagation.
- **R6.3** Export queue tests cover resolving folder-backed output destinations back to the intended output file path.
