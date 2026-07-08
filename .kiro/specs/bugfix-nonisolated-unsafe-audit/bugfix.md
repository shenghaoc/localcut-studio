# Bugfix: `nonisolated(unsafe)` Audit Follow-up

> Status: **Complete**. Tracked by GitHub PR #78.

PR #78 audits every `nonisolated(unsafe)` annotation, removes redundant
annotations where Swift 6 can prove safety, and documents the remaining unsafe
isolation boundaries. A follow-up review found two issues in the audit itself:
one new compiler warning and one false isolation-invariant comment.

## Bugs

### B1 - Overlay registry lock still used an unnecessary unsafe annotation

`EffectCompositor.overlaySourceLock` was converted from a mutable static `var`
to an immutable static `let`, but the branch kept `nonisolated(unsafe)` on the
lock. Swift 6 warns that the unsafe annotation is unnecessary for a constant
with the Sendable type `NSLock`, so the branch no longer satisfies the repo's
zero-warning merge rule.

- **Fix**: Make `overlaySourceLock` a plain `private static let NSLock`.
- **Impact**: No runtime behavior change. The registry dictionary remains
  protected by the same lock, and the mutable static registry keeps its
  `nonisolated(unsafe)` annotation.

### B2 - Live cleanup task comment overstated object confinement

`AudioMasterBus.scheduleLiveComposition` stores the `AVComposition` and
`AVAudioMix` in `currentLiveComposition` / `currentLiveAudioMix` for later
main-actor seek reuse, then captures the same read-only snapshot in a detached
decode task. The audit comment claimed the values were consumed only by the
detached task and then went out of scope, which is not true.

- **Fix**: Rewrite the comment to document the actual boundary: the main actor
  retains the immutable AVFoundation objects for seek reuse, while the detached
  decode task reads the same snapshot.
- **Impact**: No runtime behavior change. The fix keeps the scoped
  `nonisolated(unsafe)` local captures and corrects the review contract.

## Non-goals

- Do not broaden this into an `@unchecked Sendable` audit.
- Do not change live voice-cleanup scheduling behavior.
- Do not refactor overlay registry storage or preview/export overlay lifetimes.
- Do not touch unrelated fixture-generator failures.
