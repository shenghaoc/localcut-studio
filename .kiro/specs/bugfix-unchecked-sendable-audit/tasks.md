# Tasks: `@unchecked Sendable` Audit

> Status: **Complete**.

## Implementation

- [x] **T1** Document production `@unchecked Sendable` conformances with the
  concrete synchronization, confinement, immutable-wrapper, or framework
  requirement that makes each conformance safe.
- [x] **T2** Convert `ProgramCompositor.currentScene` to private storage and
  add the lock-protected `activeScene` read accessor.
- [x] **T3** Keep `VideoPublishTap.latestPixelBuffer` as the non-WebRTC
  test-facing accessor and read the private backing storage through
  `lock.withLock`.
- [x] **T4** Update `ProgramCompositorTests` and `WhipPublishTests` to use the
  synchronized accessors after the rebase onto PR #78.
- [x] **T5** Add this Kiro bugfix spec and link it from `AGENTS.md`.
- [x] **T6** Clarify `TrackPipe` as queue-confined to the serial replay-buffer
  `writerQueue` pump callback.

## Verification

- [x] **V1** `git diff --check` passed after the rebase.
- [x] **V2** `swift test --package-path Packages/LocalCutCore` passed with 173
  tests.
- [x] **V3** Focused app tests passed:
  `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme "LocalCut Studio" -destination "platform=macOS" -derivedDataPath /private/tmp/LocalCutStudio-DerivedData-audit-unchecked-sendable -only-testing:"LocalCut StudioTests/WhipPublishTests" -only-testing:"LocalCut StudioTests/ProgramCompositorTests"`.
- [x] **V4** Full app suite passed:
  `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme "LocalCut Studio" -destination "platform=macOS" -derivedDataPath /private/tmp/LocalCutStudio-DerivedData-audit-unchecked-sendable`.
- [x] **V5** PR #79 body updated with the rebased scope and validation results.
