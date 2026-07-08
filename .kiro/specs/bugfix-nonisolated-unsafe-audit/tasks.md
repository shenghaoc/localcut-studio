# Tasks: `nonisolated(unsafe)` Audit Follow-up

> Status: **Complete**.

## Implementation

- [x] **T1** Remove the redundant `nonisolated(unsafe)` annotation from
  `EffectCompositor.overlaySourceLock`.
- [x] **T2** Rewrite the `AudioMasterBus.scheduleLiveComposition` confinement
  comment so it acknowledges main-actor seek reuse and detached-task read-only
  snapshot use.
- [x] **T3** Add this Kiro bugfix spec and link it from `AGENTS.md`.
- [x] **T4** Update PR #78's body so the before/after counts, verification, and
  spec reference match the final branch.

## Verification

- [x] **V1** `git diff --check`.
- [x] **V2** `swift test --package-path Packages/LocalCutCore`.
- [x] **V3** `xcodebuild test -scheme "LocalCut Studio" -destination
  "platform=macOS"` was run after restoring the pinned WebRTC XCFramework. The
  branch-touched `EffectCompositor` warning is cleared; the command still fails
  on the pre-existing `FixtureGenerator.*` reference-fixture tests.
