# Tasks: Native Document Lifecycle

> Status: **Implemented** as unnumbered v0.1.x infrastructure. It does not
> reorder Phase 36 or create a numbered phase.

## Investigation and decision

- [x] **T1.1** Audit app shell, document controller, commands, App Intents,
  timeline, and related tests.
- [x] **T1.2** Compare the original project-persistence custom-controller
  decision with the macOS 26 SDK surface.
- [x] **T1.3** Compile-tested `ReferenceFileDocument` + `DocumentGroup` probe in
  `DocumentGroupCompatibilityTests.swift` (flat + package content types).
- [x] **T1.4** Record the production **no-go** as an engineering trade-off:
  retain the custom file-based controller rather than duplicate the package
  pipeline for `FileWrapper` callbacks.

## File-based project classification

- [x] **T2.1** Add `ProjectStorageKind` + `ProjectLocationInspector` with full
  metadata validation for bundles.
- [x] **T2.2** Persist storage kind with `documentURL`; Save uses stored kind;
  Save As uses destination representation.
- [x] **T2.3** Replace loose `project.json` existence sniffs; update
  `ProjectBundle.isBundle` to real validation.
- [x] **T2.4** Tests for valid/invalid `.lcstudio` / `.lcbundle` / extensionless
  bundle / empty JSON / malformed / unrelated directory / save routing.

## App Intent readiness

- [x] **T3.1** Replace multi-document-shaped registry with
  `ActiveEditorRegistry` (window readiness only).
- [x] **T3.2** Cold-launch wait for New / Diagnostics / Import / Export;
  typed `editorUnavailable` and `targetWindowClosed`.
- [x] **T3.3** Cancellation-safe readiness wait; serialized actions; no silent
  retargeting.
- [x] **T3.4** Tests for cold-launch, timeout, cancellation, serialization,
  window-lost queue failure.

## SwiftUI shell cleanup

- [x] **T4.1** Inspector `@SceneStorage` + focused View-menu binding.
- [x] **T4.2** Timeline `onKeyPress` + pure policy; one-shot initial focus;
  click reclaims focus without steal-on-reappear.
- [x] **T4.3** Scene placement/restoration; narrow `WindowConfigurator`.
- [x] **T4.4** OTIO/EDL via `fileExporter`; retain `NSSavePanel` for queued
  video export.
- [x] **T4.5** `TimelineFocusUITests` harness for focus transitions (policy
  unit tests remain mapping-only).

## Documentation and verification

- [x] **T5.1** Feature spec is the detailed source of truth; historical specs
  get short supersession notes only.
- [x] **T5.2** Architecture/testing steering use “local filesystem URL”
  language and accurate DocumentGroup trade-off wording.
- [x] **V1** Focused suites pass under `xcodebuild test`.
- [x] **V2** Full macOS scheme tests, core SwiftPM tests, `git diff --check`.
- [ ] **V3** Manual checklist in `.kiro/steering/testing.md` — complete live
  GUI checks or keep the PR draft with outstanding items listed honestly.
