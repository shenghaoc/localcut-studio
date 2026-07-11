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

The production audit covers 30 conformances before and after this PR. No
conformance was clearly unnecessary after inspection, so the risk reduction is
documentation plus the small local synchronization/accessor fixes called out
below.

| Category | Count | Examples |
| --- | ---: | --- |
| Lock-protected mutable state | 18 | `ScreenCaptureSession`, `RingBuffer`, `ReconnectController`, `VideoPublishTap`, `ProgramCompositor` |
| Queue-confined framework state | 4 | `CaptureManifestFileWriter`, `VoiceCleanupStateBox`, `AVCaptureSampleSession`, `TrackPipe` |
| Immutable wrapper for non-Sendable framework object | 6 | `ProgramFrameBuffer`, `LiveAudioPCMBufferBox`, `WriterBox`, `PendingVideoCompositionRequest` |
| Framework protocol requirement | 2 | `LocalCutAudioDevice`, `EffectCompositionInstruction` |

## Audit Table

| File | Type | Risk | Action | Synchronization/threading contract |
| --- | --- | --- | --- | --- |
| `CaptureRunningSessions.swift` | `ScreenCaptureSession` | Medium | Keep with comment | `stateLock` protects target, stream, writers, and exclusions; ScreenCaptureKit callbacks and `dropNextScreenFrame` are confined to `outputQueue`. |
| `CaptureRunningSessions.swift` | `AVCaptureSampleSession` | Medium | Keep with comment | AVFoundation sample callbacks mutate processor/audio-level state only on the configured delegate `queue`. |
| `AudioPublishBridge.swift` | `LocalCutAudioDeviceModuleDelegate`, `LocalCutAudioSourceRenderer` | Medium | Keep with comment | WebRTC invokes these from its worker/render threads; mutable render storage is confined to the audio callback and shared samples use the locked `RingBuffer`. |
| `CaptureWriters.swift` | `CaptureManifestFileWriter` | Low | Keep with comment | `FileHandle` writes and close are serialized on the private manifest queue. |
| `CaptureWriters.swift` | `ContinuousCaptureWriter` | Medium | Keep with comment | Writer lifecycle, timing, and sample counters are protected by `lock`; AVFoundation writer objects remain framework-owned. |
| `LottieFrameSource.swift` | `LottieFrameSource` | Medium | Keep with comment | Cache and cache order are protected by `lock`; renderer metadata is immutable and rasterization remains on the expected main-actor path. |
| `AnimatedImageSource.swift` | `AnimatedImageSource` | Low | Keep with comment | Frame cache is protected by `lock`; frame metadata is immutable after initialization. |
| `AlphaVideoSource.swift` | `AlphaVideoSource` | Medium | Keep with comment | Cache and cache order are protected by `lock`; `AVAssetImageGenerator.image(at:)` is used as the framework async boundary. |
| `ReplayBufferFinalizer.swift` | `TrackPipe` | Medium | Keep with comment | Non-Sendable reader/writer pair is queue-confined to `requestMediaDataWhenReady(on: writerQueue)` callbacks on the serial `writerQueue`. |
| `ReplayBufferFinalizer.swift` | `WriterBox` | Low | Keep with comment | Immutable wrapper around a non-Sendable `AVAssetWriter` passed through async finalization. |
| `RingBuffer.swift` | `RingBuffer` | Low | Keep with comment | Buffer indices, count, and storage are protected by `OSAllocatedUnfairLock`. |
| `EditorModel+Commands.swift` | `PanelCancellationHandle` | Low | Keep with comment | `NSSavePanel` handle is created and consumed on `@MainActor`; it is not sent across actors directly. |
| `FrameScaler.swift` | `FrameScaler` | Low | Keep with comment | All stored properties are immutable; the instance is owned by one capture session and used from that session output queue. |
| `LiveComposeTap.swift` | `LiveComposeTap` | Low | Keep with comment | Disposed flag is protected by `lock`; pixel buffers remain zero-copy references. |
| `LiveVoiceCleanupPreviewPipeline.swift` | `LiveVoiceCleanupSettingsStore` | Low | Keep with comment | Settings value is protected by `OSAllocatedUnfairLock`. |
| `LiveVoiceCleanupPreviewPipeline.swift` | `LiveQueuedFrameCounter` | Low | Keep with comment | Frame count is protected by `OSAllocatedUnfairLock`. |
| `LiveVoiceCleanupPreviewPipeline.swift` | `LiveGainReductionStore` | Low | Keep with comment | Gain-reduction state is protected by `OSAllocatedUnfairLock`. |
| `LiveVoiceCleanupPreviewPipeline.swift` | `LiveAudioPCMBufferBox` | Low | Keep with comment | Immutable wrapper for a non-Sendable `AVAudioPCMBuffer` crossing async boundaries. |
| `ProgramCompositor.swift` | `ProgramCompositor` | Medium | Add lock-protected accessor | Per-source buffers, current scene, scene list, and transition state are protected by `lock`; `activeScene` reads through the same lock. |
| `ProgramSession.swift` | `ProgramFrameBuffer` | Low | Keep with comment | Immutable wrapper for non-Sendable `CVPixelBuffer`. |
| `RenderCache.swift` | `MemoryNode` | Low | Keep with comment | Linked-list pointers mutate only under the parent render-cache lock. |
| `RenderCache.swift` | `DiskNode` | Low | Keep with comment | Linked-list pointers mutate only under the parent render-cache lock. |
| `RenderQueue.swift` | `ResumeBox` | Low | Keep with comment | Single resume flag is protected by `OSAllocatedUnfairLock`. |
| `RenderQueue.swift` | `VoiceCleanupStateBox` | Low | Keep with comment | State is confined to the AVFoundation pump request block on the serial `pumpQueue`. |
| `TitleRaster.swift` | `CacheNode` | Low | Keep with comment | Linked-list pointers mutate only under the parent title-raster cache lock. |
| `EffectCompositor.swift` | `EffectCompositionInstruction` | Low | Keep with comment | Immutable instruction required by `AVVideoCompositionInstructionProtocol`. |
| `EffectCompositor.swift` | `PendingVideoCompositionRequest` | Medium | Keep with comment | Non-Sendable request is paired with a task handle inside a lock-protected pending-request dictionary. |
| `ReconnectController.swift` | `ReconnectController` | Low | Keep with comment | Reconnect counters, ETag, ICE servers, restart flag, and disconnect time are protected by `OSAllocatedUnfairLock`; test seams are immutable `let` closures. |
| `VideoPublishTap.swift` | `VideoPublishTap` | Medium | Add lock-protected accessor | WebRTC source/capturer and frame delivery state are protected by `lock`; non-WebRTC `latestPixelBuffer` reads private storage through `lock.withLock`. |

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
- Follow-up PRs: no high-risk unsafe `@unchecked Sendable` items remain from
  this audit.
