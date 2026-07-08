# Design: `nonisolated(unsafe)` Audit Follow-up

This is a narrow hygiene follow-up to PR #78. It removes redundant unsafe
annotations, replaces small locally-fixable unsafe access patterns, and
documents the remaining isolation boundaries. It does not change media pipeline,
UI, persistence, export, or timeline behavior.

## Approach

1. Remove unsafe annotations when Swift can now prove the declaration safe.
2. Keep unsafe annotations where they express a real isolation boundary.
3. Replace mutable unprotected state with existing synchronization or immutable
   injection when the fix is small and local.
4. Make every remaining isolation comment describe the code that actually runs,
   not an idealized confinement story.

## Overlay Registry Lock

`EffectCompositor.overlaySourceLock` is an immutable static `NSLock`. `NSLock`
is Sendable, and the value never changes after static initialization, so Swift
does not need `nonisolated(unsafe)` to allow access from the compositor's
nonisolated static helpers.

The mutable registry remains:

```swift
nonisolated(unsafe) private static var overlaySourceRegistries: [UUID: OverlaySourceRegistry] = [:]
```

All access to that dictionary is still guarded by `overlaySourceLock`. The lock
change only removes a redundant escape hatch from the immutable guard object.

## Video Tap Latest Frame

The non-WebRTC `VideoPublishTap` path exists so tests can verify that frames
reach the publishing tap even when WebRTC is not compiled in. The baseline
stored property was written under `lock` but read without synchronization. The
branch now keeps private backing storage and exposes a computed getter that
acquires the existing `NSLock`, so the unsafe annotation is removed instead of
documented.

## Reconnect Timing Dependencies

`ReconnectController.clock` and `ReconnectController.sleep` are deterministic
test seams. They are conceptually constructor dependencies, not runtime mutable
state. The branch converts them to immutable `nonisolated let` properties
injected through the initializer, and updates tests to pass the probe closures at
construction time.

## Live Cleanup Snapshot Comment

`AudioMasterBus` is `@MainActor`, but live voice cleanup decodes and processes
bounded PCM chunks in a detached task so the main actor does not block on media
decode or DSP. `AVComposition` and `AVAudioMix` are not Sendable, yet this path
uses them as immutable read-only inputs:

- the main actor stores them for later `seekLivePreview(to:)` reuse;
- the detached task captures the same references as one decode snapshot;
- settings, queue depth, and gain-reduction state cross executors through their
  own thread-safe helper types.

The scoped `nonisolated(unsafe)` locals are therefore still the minimal
expression of the boundary, but the comment must name the shared immutable
snapshot rather than claim detached-task-only ownership.

## Validation Strategy

- `git diff --check` for whitespace.
- `swift test --package-path Packages/LocalCutCore` as the fast shared-model
  gate.
- `xcodebuild test -scheme "LocalCut Studio" -destination "platform=macOS"` for
  the app build and suite. The branch is considered warning-clean only if the
  branch-touched warning disappears. Pre-existing fixture-generator failures are
  reported separately if they remain.
- `rg "nonisolated\\(unsafe\\)" "LocalCut Studio" Packages` to confirm the
  final count and retained files.

## Non-goals

- Changing the app's actor model.
- Adding new lock primitives, actors, or wrapper types.
- Changing preview/export overlay cache semantics.
- Fixing the reference fixture generator in this PR.
