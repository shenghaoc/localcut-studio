# Tasks: Native Document Lifecycle

> Status: **Implemented** as unnumbered v0.1.x infrastructure. It does not
> reorder Phase 36 or create a numbered phase.

## Investigation and decision

- [x] **T1.1** Audit `LocalCutStudioApp`, `DocumentCommands`,
  `WindowConfigurator`, `DocumentController`, `EditorModel`, command and
  persistence extensions, App Intents, timeline, split-view bridge, project
  model/bundle, and their relevant tests.
- [x] **T1.2** Compare the original project-persistence T2.1 custom-controller
  decision with the current macOS 26 SDK and actual persistence behaviour.
- [x] **T1.3** Add a compile-tested `ReferenceFileDocument` + `DocumentGroup`
  adapter spike in `NativeDocumentLifecycleSpikeTests.swift` that covers flat
  and package wrapper forms.
- [x] **T1.4** Record the explicit macOS 26 **no-go** for a production
  `DocumentGroup` migration, with the documented URL/async/FileWrapper reason.

## Active-document routing

- [x] **T2.1** Add `ActiveDocumentRegistry` with stable weak editor tokens,
  activation ordering, unregister behaviour, and no silent retargeting.
- [x] **T2.2** Route `LocalCutAppIntentRouter` through the registry; add typed
  `noActiveDocument` and `targetDocumentClosed` errors.
- [x] **T2.3** Register on scene appearance/key-window activation and unregister
  on disappearance while retaining the existing serialized command paths.
- [x] **T2.4** Test no-window, one-active-editor, two-editor capture, stable
  tokens, close/no-retargeting, and cancellation/serialization behaviour.

## SwiftUI shell cleanup

- [x] **T3.1** Move inspector presentation state to `@SceneStorage` and expose
  a focused View-menu binding.
- [x] **T3.2** Replace the timeline raw `NSEvent` monitor with focused
  `onKeyPress`, `onDeleteCommand`, and a tested pure policy mapper.
- [x] **T3.3** Replace manual initial-frame logic with scene default/ideal
  placement and automatic restoration; add placement-policy tests.
- [x] **T3.4** Narrow `WindowConfigurator` to URL/dirty/close/key activation and
  retain the split-divider bridge for its still-missing SwiftUI capability.
- [x] **T3.5** Move OTIO/EDL destination presentation to `fileExporter` and EDL
  track selection to `confirmationDialog`; retain `NSSavePanel` for queued
  AVFoundation renders.

## Documentation and verification

- [x] **T4.1** Add this unnumbered feature spec and link it from `AGENTS.md`.
- [x] **T4.2** Update durable architecture, persistence, and testing guidance to
  describe selected ownership, routing, manual checks, and the no-go boundary.
- [x] **V1** Focused lifecycle suites pass under `xcodebuild test`.
- [x] **V2** Run the full macOS scheme test suite, core SwiftPM tests, and
  diff hygiene.
- [ ] **V3** Complete the remaining honest manual lifecycle checklist before
  merge: destructive **Don't Save** (requires explicit confirmation at the
  time of the action), real privacy-granted recording, queued render, external
  bundle-change/relink, and Shortcuts app invocation. The automated test suite
  covers the command guards and active-document routing; these are retained as
  live integration checks.
