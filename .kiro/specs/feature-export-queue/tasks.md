# Tasks: Export Presets + Render Queue

> Status: **Implemented**.

## Preset model

- [x] **T1.1** Define `ExportAspect`, `ExportBitrateBracket`, `AudioConfig`,
  and `ExportPreset` value types in `LocalCut Studio/ExportPresets.swift` per
  the [design](./design.md#preset-model-localcut-studioexportpresetsswift).
- [x] **T1.2** Implement `ExportPreset.isSupportedCombination(container:codec:)`
  with the documented allow-list.
- [x] **T1.3** Ship `BuiltInExportPresets.all` covering YouTube 1080p,
  YouTube 4K, Instagram 9:16, TikTok 9:16, ProRes 4K, Web 720p.

## Queue engine

- [x] **T2.1** Define `QueueJob` and `QueueJobStatus` in
  `LocalCut Studio/RenderQueue.swift`.
- [x] **T2.2** Implement `RenderQueue` as `@Observable @MainActor final class`
  with `jobs`, `currentJobID`, `totalProgress`, `isRunning`, `statusMessage`
  plus `enqueue`, `cancel`, `clearCompleted`, `start`, `stop`.
- [x] **T2.3** Implement the per-job execution path: build composition from
  the snapshot, choose `AVAssetExportSession` preset name when available,
  fall back to `AVAssetWriter` otherwise.
- [x] **T2.4** Wire `AVAssetExportSession.states(updateInterval:)` to
  `QueueJob.progress`; recompute `totalProgress` on every job update.
- [x] **T2.5** Emit one `os_log` line per status transition under category
  `render-queue`.

## Persistence

- [x] **T3.1** Define a versioned `RenderQueueDoc` and write atomically to
  `~/Library/Application Support/LocalCut Studio/queue.json` after every
  transition.
- [x] **T3.2** On launch, `RenderQueue.load()` rewinds any `running` job to
  `queued`; jobs with an unresolvable `outputBookmark` transition to `failed`
  with the documented message.
- [x] **T3.3** Document the security-scoped bookmark requirement for output
  URLs in `design.md` and in code comments where the bookmark is captured /
  resolved.

## UI

- [x] **T4.1** Add `RenderQueueInspectorView` mirroring
  `CaptionsInspectorView`'s shape; surface every built-in preset with an
  "Add to Queue…" button.
- [x] **T4.2** Show the live queue with status pills + cancel buttons.
- [x] **T4.3** Re-route the existing toolbar/menu Export action through
  `RenderQueue.enqueueWithDefaultPreset(outputURL:)`.

## Verification

- [x] **T5.1** Unit test: `ExportPreset` Codable round-trip preserves every
  field (R5.1).
- [x] **T5.2** Unit test: every `BuiltInExportPresets.all` entry passes
  `isSupportedCombination` (R5.2).
- [x] **T5.3** Unit test: queue enqueue / dequeue preserves insertion order
  (R5.3).
- [x] **T5.4** Unit test: cancellation transitions (R5.4).
- [x] **T5.5** Unit test: `RenderQueueDoc` round-trip; stale-bookmark
  fallback marks job `failed` (R5.5).
- [x] **T5.6** `xcodebuild` (Debug, macOS) green; no test count regression
  (R5.6).
