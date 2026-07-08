# Tasks: `nonisolated(unsafe)` Audit Follow-up

> Status: **Complete**.

## Implementation

- [x] **T1** Remove the redundant `nonisolated(unsafe)` annotation from
  `EffectCompositor.overlaySourceLock`.
- [x] **T2** Rewrite the `AudioMasterBus.scheduleLiveComposition` confinement
  comment so it acknowledges main-actor seek reuse and detached-task read-only
  snapshot use.
- [x] **T3** Replace `VideoPublishTap.latestPixelBuffer` with a
  lock-protected computed getter backed by private storage.
- [x] **T4** Convert `ReconnectController.clock` and `sleep` from mutable
  unsafe test seams to immutable initializer dependencies, and update the
  timing test.
- [x] **T5** Add the full audit table in [`audit.md`](audit.md).
- [x] **T6** Add this Kiro bugfix spec and link it from `AGENTS.md`.
- [x] **T7** Update PR #78's body so the before/after counts, verification, and
  spec reference match the final branch.

## Verification

- [x] **V1** `git diff --check` — passed.
- [x] **V2** `xcodebuild build -project "LocalCut Studio.xcodeproj" -scheme
  "LocalCut Studio" -configuration Debug -destination 'platform=macOS'` —
  passed.
- [x] **V3** `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme
  "LocalCut Studio" -configuration Debug -destination 'platform=macOS'` —
  passed.
- [x] **V4** `swift test --package-path Packages/LocalCutCore` — passed, 173
  Swift Testing tests.
- [x] **V5** `rg "nonisolated\\(unsafe\\)" "LocalCut Studio" Packages` — 26
  raw text matches, 22 production annotations, no `Packages/` matches.
