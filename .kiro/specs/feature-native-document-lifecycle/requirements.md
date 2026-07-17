# Requirements: Native Document Lifecycle

> Status: **Implemented** as unnumbered v0.1.x infrastructure. This feature
> does not consume a release slot or change the numbered-phase order.

## R1 — Evidence-led document-scene decision

- **R1.1** A compile-tested macOS 26 probe must evaluate `DocumentGroup` /
  `ReferenceFileDocument` flat-file and package shapes before a production
  migration is chosen.
- **R1.2** The design records an engineering trade-off (not “impossibility”):
  `DocumentGroup` is technically feasible, but macOS 26’s
  `ReferenceFileDocument` does not directly reuse LocalCut’s filesystem-URL-based
  asynchronous package pipeline, so this feature retains the custom controller.
- **R1.3** The feature must not introduce SwiftData, change the project schema,
  or change `.lcstudio` / `.lcbundle` compatibility merely to adopt a shell API.

## R2 — Persistence and lifecycle safety

- **R2.1** `.lcstudio` and `.lcbundle` saves remain atomic, streamed where
  needed, fingerprinted, security-scoped, and compatible with the existing
  project/document services.
- **R2.2** Open classification uses one inspector path that fully validates
  bundle metadata (`project.json` decode + supported `bundleFormat`). Existence
  of `project.json` alone is insufficient, and metadata reads are size-bounded
  before decoding.
- **R2.3** Session state stores `ProjectStorageKind` beside the local filesystem
  `documentURL`. Save and queued bundle-asset snapshots dispatch from the
  stored kind; Save As dispatches from the panel-selected representation.
- **R2.4** Missing-media relinking, schema/downconversion protection, external
  change warnings, render-queue persistence, and preview/export parity remain
  owned by their existing services.
- **R2.5** Dirty state, undo labels/grouping, recording guards, and asynchronous
  save-before-close behaviour must not regress.

## R3 — App Intent editor readiness

- **R3.1** The app owns one process-wide `EditorModel`. App Intents must not
  pretend multi-document GUI support exists.
- **R3.2** Cold-launch New Project and Show Diagnostics work once the editor
  window is ready, without requiring a previously opened project file.
- **R3.3** Import and Export foreground the app, wait for editor readiness, then
  reuse existing command paths (including empty-timeline export error).
- **R3.4** If the editor window cannot become available, fail with a typed
  `editorUnavailable` error — not “open a project first.”
- **R3.5** Queued window-dependent actions are pinned to the ready-window
  generation that satisfied cold-launch readiness. Actions that lose that
  editor fail with `targetWindowClosed` and never silently retarget.
- **R3.6** Concurrent intent actions remain serialized; cancellation while
  waiting for readiness finishes promptly.

## R4 — Native SwiftUI shell equivalents

- **R4.1** Inspector visibility is scene-scoped presentation state, not
  model-owned persistence.
- **R4.2** Timeline shortcuts use focused SwiftUI `onKeyPress`; text fields and
  focused buttons/toggles keep Space / M / Delete semantics.
- **R4.3** Window placement uses scene APIs; the AppKit bridge stays narrow
  (dirty state, represented filesystem URL, readiness, close veto).
