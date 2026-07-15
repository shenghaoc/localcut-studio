# Requirements: Native Document Lifecycle

> Status: **Implemented** as unnumbered v0.1.x infrastructure. This feature
> does not consume a release slot or change the numbered-phase order.

## R1 — Evidence-led document-scene decision

- **R1.1** A compile-tested macOS 26 spike must evaluate `DocumentGroup`,
  `ReferenceFileDocument`, flat-file and package `FileWrapper` shapes before a
  production migration is chosen.
- **R1.2** The design records an explicit go/no-go outcome for a full native
  document scene, including the reason the existing URL-based controller is
  retained or removed.
- **R1.3** The feature must not introduce SwiftData, change the project schema,
  or change `.lcstudio` / `.lcbundle` compatibility merely to adopt a shell API.

## R2 — Persistence and lifecycle safety

- **R2.1** `.lcstudio` and `.lcbundle` saves remain atomic, streamed where
  needed, fingerprinted, security-scoped, and compatible with the existing
  project/document services.
- **R2.2** Missing-media relinking, schema/downconversion protection, bundle
  access, external-change warnings, render-queue persistence, and preview / export
  parity remain owned by their existing services.
- **R2.3** Dirty state, undo labels/grouping, recording guards, and asynchronous
  save-before-close behaviour must not regress.

## R3 — Active-document intent routing

- **R3.1** The App Intent router resolves the focused or most-recently-active
  registered editor instead of retaining an `EditorModel` itself.
- **R3.2** When no editor is active (including cold launch before a scene
  registers), an intent fails with a clear typed `noActiveDocument` error.
- **R3.3** A queued action captures a registry token and verifies that exact
  editor before running; a closed target must not be silently redirected to a
  different window.
- **R3.4** Concurrent intent actions remain serialized and keep using the
  existing command/result paths.

## R4 — Native SwiftUI shell equivalents

- **R4.1** Inspector visibility is restorable per scene, not project content or
  application-model state; the active View menu targets it through a focused
  binding.
- **R4.2** Timeline Space, M, Shift-M, and Delete use focused SwiftUI
  `onKeyPress` / semantic delete handling rather than a raw window event
  monitor. Text fields and focused controls retain first refusal.
- **R4.3** Fresh-window sizing and placement use scene APIs
  (`defaultWindowPlacement`, `windowIdealPlacement`, and restoration behavior)
  without manual `NSWindow.setFrame` or one-shot defaults flags.
- **R4.4** Small serialized OTIO and EDL exports use SwiftUI `fileExporter`;
  EDL track selection uses `confirmationDialog`. Streamed AVFoundation render
  destinations continue to use `NSSavePanel`.

## R5 — Narrow, justified AppKit interop

- **R5.1** Keep `WindowConfigurator` only for dirty/represented URL mirroring,
  key-window registration, and the async close veto that SwiftUI does not
  provide on macOS 26.
- **R5.2** Retain `SplitViewAutosaveConfigurator` until SwiftUI offers divider
  position autosaving that preserves the existing collapsed-rail invariant.
- **R5.3** Do not remove a working AppKit flow merely to lower AppKit line count.

## R6 — Verification and manual coverage

- **R6.1** Add deterministic tests for the selected architecture: API spike,
  active-document routing, no-active intent errors, intent serialization,
  shortcut policy, and scene placement policy.
- **R6.2** The test count must not decrease. Existing persistence, undo,
  recording, security-scope, and render-queue coverage remains in force.
- **R6.3** The testing steering document carries an honest manual verification
  checklist for GUI-only document, shortcut, App Intent, recording, and render
  behaviours.
