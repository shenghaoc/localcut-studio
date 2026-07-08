# Bugfix: `nonisolated(unsafe)` Audit Follow-up

> Status: **Complete**. Tracked by GitHub PR #78.

PR #78 audits every production `nonisolated(unsafe)` annotation, removes
redundant annotations where Swift 6 can prove safety, replaces two local unsafe
access patterns, and documents the remaining isolation boundaries. Follow-up
review found the branch still needed one warning fix, one comment correction,
and two small local replacements rather than comments that excused mutable
shared state.

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

### B3 - Video tap latest-frame accessor only protected writes

`VideoPublishTap.latestPixelBuffer` was mutable state on a `@unchecked Sendable`
class. The baseline code wrote the buffer under `lock` but allowed reads without
that lock in the non-WebRTC path.

- **Fix**: Replace the unsafe stored property with a lock-protected computed
  getter backed by private storage that is written under the existing lock.
- **Impact**: No product behavior change. The non-WebRTC test seam still exposes
  the latest captured frame, but reads now use the same synchronization as
  writes.

### B4 - Reconnect test seams were mutable after construction

`ReconnectController.clock` and `ReconnectController.sleep` were mutable
`nonisolated(unsafe)` closures used as deterministic test seams. Production code
never mutates them after construction, and tests only set them immediately after
constructing the controller.

- **Fix**: Convert both seams to immutable `nonisolated let` dependencies
  injected through the initializer, and update tests to pass the probe at
  construction time.
- **Impact**: No product behavior change. The timing logic is unchanged; the
  mutation window is removed.

### B5 - Bundle security-scoped grant cleanup was documented but not balanced

`EditorModel.bundleAccessURL` intentionally remains outside `accessedURLs` so
undo/redo reconciliation cannot revoke the outer `.lcbundle` directory grant
while media items point at files inside that bundle. The audit comment said the
grant was balanced during teardown, but `EditorModel.deinit` only stopped
`accessedURLs` and `recordingsFolderAccessURL`.

- **Fix**: Stop `bundleAccessURL` in `EditorModel.deinit`.
- **Impact**: No product behavior change beyond matching the documented
  resource-lifetime invariant and preventing a teardown leak of the bundle
  security-scoped grant.

## Audit Notes

See [`audit.md`](audit.md) for the full working audit table, before/after
counts, classifications, actions, and follow-up assessment.

## Non-goals

- Do not broaden this into an `@unchecked Sendable` audit.
- Do not change live voice-cleanup scheduling behavior.
- Do not refactor overlay registry storage or preview/export overlay lifetimes.
- Do not touch unrelated fixture-generator failures.
