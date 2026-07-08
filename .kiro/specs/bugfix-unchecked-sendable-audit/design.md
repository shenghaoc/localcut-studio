# Design: `@unchecked Sendable` Audit

This spec covers the narrow PR #79 follow-up after rebasing onto current
`origin/main`. The related `nonisolated(unsafe)` audit is already complete in
[`../bugfix-nonisolated-unsafe-audit`](../bugfix-nonisolated-unsafe-audit/tasks.md);
this spec only covers `@unchecked Sendable` conformances.

## Approach

1. Keep each conformance only when there is a concrete synchronization,
   confinement, immutable-wrapper, or framework-protocol reason.
2. Put the invariant next to the conformance so future edits do not rely on PR
   discussion or reviewer memory.
3. Prefer existing locks and queues over new abstractions.
4. Preserve public/test-facing names where current `origin/main` already
   stabilized them.

## Classification

The production audit covers 30 conformances:

| Category | Count | Examples |
| --- | ---: | --- |
| Lock-protected mutable state | 18 | `ScreenCaptureSession`, `RingBuffer`, `ReconnectController`, `VideoPublishTap`, `ProgramCompositor` |
| Queue-confined framework state | 4 | `CaptureManifestFileWriter`, `VoiceCleanupStateBox`, `AVCaptureSampleSession`, `TrackPipe` |
| Immutable wrapper for non-Sendable framework object | 6 | `ProgramFrameBuffer`, `LiveAudioPCMBufferBox`, `WriterBox`, `PendingVideoCompositionRequest` |
| Framework protocol requirement | 2 | `LocalCutAudioDevice`, `EffectCompositionInstruction` |

## Program Compositor Accessor

`ProgramCompositor` protects `sourceBuffers`, `currentScene`, scene lists, and
transition state with `lock`. The previous `private(set)` scene property made
reads look cheaper than they were. The branch keeps mutation inside the lock and
adds `activeScene` for read-only tests and diagnostics.

## Video Publish Tap Accessor

The non-WebRTC build path is a deterministic test seam, but it is still part of
a `@unchecked Sendable` type. `latestPixelBuffer` remains the accessor used by
tests, and its implementation now uses `lock.withLock` against private backing
storage.

## Replay Buffer Track Pipe

`TrackPipe` wraps an `AVAssetReaderTrackOutput` and `AVAssetWriterInput`.
Those framework objects are safe for this finalizer only because every pipe is
used by `requestMediaDataWhenReady(on: writerQueue)` callbacks on the same
serial `writerQueue`. The unchecked contract therefore names queue confinement
as the boundary.

## Validation Strategy

- `git diff --check`.
- `swift test --package-path Packages/LocalCutCore`.
- Focused app tests for touched suites:
  `xcodebuild test ... -only-testing:"LocalCut StudioTests/WhipPublishTests" -only-testing:"LocalCut StudioTests/ProgramCompositorTests"`.
- Full app suite:
  `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme "LocalCut Studio" -destination "platform=macOS" -derivedDataPath /private/tmp/LocalCutStudio-DerivedData-audit-unchecked-sendable`.

## Non-goals

- Actor redesign.
- Removing Sendable conformances needed for AVFoundation, WebRTC, or test seam
  transfer.
- Reworking cache eviction, overlay registry lifetime, or capture/publish
  queues.
