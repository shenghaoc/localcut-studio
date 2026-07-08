# Requirements: Export Presets + Render Queue

## R1 — Preset model

- **R1.1** `ExportPreset` is a Codable, Hashable, Sendable value type with
  `id`, `name`, `containerFormat` (`AVFileType` raw value), `videoCodec`
  (`AVVideoCodecType` raw value), `aspect`, `targetSize`, `bitrate` bracket,
  optional `frameRate`, and an `audioConfig` (codec + bitrate + sample rate +
  channels).
- **R1.2** `BuiltInExportPresets.all` ships at least six presets: YouTube
  1080p, YouTube 4K, Instagram 9:16, TikTok 9:16, ProRes 4K, Web 720p.
- **R1.3** Every built-in preset's `(containerFormat, videoCodec)` pair is in
  `ExportPreset.isSupportedCombination`. Unsupported combos are rejected at
  enqueue.
- **R1.4** The preset model is shipped from `LocalCut Studio/ExportPresets.swift`
  in the same shape as `LocalCut Studio/CaptionPresets.swift` — a Codable
  value type plus a `BuiltInExportPresets` enum holding the static list.
- **R1.5** `ExportPreset` Codable round-trips through `JSONEncoder` /
  `JSONDecoder` without losing any field.

## R2 — Queue engine

- **R2.1** `RenderQueue` is an `@Observable final class` holding an ordered
  `[QueueJob]`. Each job carries the preset, a security-scoped output
  bookmark, the project snapshot (`ProjectDocument`), a status, a progress
  value, and an optional error message.
- **R2.2** Jobs run **serially**: at most one `running` job at a time. The
  next `queued` job starts as soon as the current one finishes.
- **R2.3** `enqueue(_:)` appends to the queue and starts the runner if it
  isn't already running. `cancel(jobID:)` aborts the matching job — `running`
  → `cancelled`, `queued` → `cancelled` immediately.
- **R2.4** Cancellation of the in-flight job uses
  `AVAssetExportSession.cancelExport()` (preferred path) or
  `AVAssetWriter.cancelWriting()` (fallback path) and transitions the job to
  `cancelled` before returning to the queue loop.
- **R2.5** Progress is reported per job (`QueueJob.progress`) and as a queue-
  wide aggregate (`RenderQueue.totalProgress`). The aggregate is
  `(completed + active.progress) / total`.
- **R2.6** Every status transition emits a single `os_log` line via a
  `Logger(subsystem:, category: "render-queue")` instance. No multi-line
  structured payloads.
- **R2.7** `RenderQueue` prefers `AVAssetExportSession` when a preset matches a
  `AVAssetExport…` constant; it falls back to `AVAssetWriter` for combinations
  with no matching export-session preset. Combinations not in
  `isSupportedCombination` are rejected at enqueue and never reach either
  path.
- **R2.8** Runner cleanup is tokenized: an old runner task cannot reset
  `isRunning` for a newer runner, and a job enqueued while the previous runner
  is draining is picked up automatically unless the user explicitly stopped the
  queue.

## R3 — Persistence

- **R3.1** The queue is persisted to
  `~/Library/Application Support/LocalCut Studio/queue.json` after every
  status transition, atomically.
- **R3.2** On launch, `RenderQueue.load()` reads the file (if present),
  transitioning any `running` job back to `queued` (no resume API exists for
  `AVAssetExportSession`; the cleanest "resume" is to restart with the same
  snapshot + output URL).
- **R3.3** A job whose `outputBookmark` no longer resolves on load transitions
  to `failed("Output destination unavailable")` instead of being silently
  dropped, so the user can retry from the UI by re-adding the destination.
- **R3.4** Output destinations require **security-scoped bookmarks** because
  the App Sandbox does not grant arbitrary write access. The bookmark is
  captured at enqueue (after the `NSSavePanel`) with `.withSecurityScope`
  and resolved per job-run with `startAccessingSecurityScopedResource()` /
  `stopAccessingSecurityScopedResource()`.
- **R3.5** `~/Library/Application Support/…` lives **inside** the App Sandbox
  container, so the queue file itself does not require a security-scoped
  bookmark.
- **R3.6** The on-disk doc carries a `version` field; a build that reads a
  newer-version file refuses to overwrite it (matching the project-document
  rule).
- **R3.7** Stale-but-resolvable output and source-media bookmarks are refreshed
  back into the queued job before the next persist, rather than being used once
  and left stale on disk.
- **R3.8** If the queue file location cannot be created or an atomic queue write
  fails, `RenderQueue` logs the failure and updates `statusMessage` so the user
  is not left believing the queue state was saved.

## R4 — UI

- **R4.1** A `Renders` section in the inspector lists every built-in preset
  with an "Add to Queue…" button that opens an `NSSavePanel` constrained to
  the preset's container, then enqueues a job for the picked destination.
- **R4.2** The same section lists the current queue with each job's status
  pill (`queued`, `running NN%`, `completed`, `cancelled`, `failed`) and a
  cancel button for queued / running rows. Failed rows surface the job's
  `errorMessage` beneath the pill so the user can act on the failure reason.
- **R4.3** The existing single-shot Export toolbar action becomes a shortcut
  for "queue with the default preset (YouTube 1080p) and start immediately".
- **R4.4** A `ProgressView` renders `totalProgress` as an aggregate progress
  bar above the job list while the queue is running (`isRunning == true`).

## R5 — Verification

- **R5.1** `ExportPreset` Codable round-trip preserves every field exactly
  through `JSONEncoder` / `JSONDecoder`.
- **R5.2** Every preset in `BuiltInExportPresets.all` passes
  `ExportPreset.isSupportedCombination`.
- **R5.3** Queue enqueue / dequeue preserves insertion order: jobs appended
  in order `[A, B, C]` are popped in order `A, B, C`.
- **R5.4** Cancellation transitions:
  - `queued` → `cancelled` on `cancel(jobID:)` when not running.
  - `cancelled` is terminal — re-cancelling is a no-op.
- **R5.5** `RenderQueueDoc` Codable round-trips through the same encoder
  pair; a job whose `outputBookmark` is unresolvable on `load()` transitions
  to `failed` with the documented message, not dropped.
- **R5.6** Reconciliation refreshes a stale output bookmark when resolution
  succeeds and supplies replacement bookmark data.
- **R5.7** A job enqueued in the runner-drain / cleanup window still runs after
  cleanup instead of remaining queued behind a false `isRunning` state. The
  regression test must avoid real security-scoped bookmark resolution by
  injecting a deterministic output-bookmark resolver.
- **R5.8** Queue persistence failure tests cover both an unavailable queue-file
  URL and an atomic-write failure, asserting that `statusMessage` is updated.
- **R5.9** `xcodebuild` (Debug, macOS) compiles cleanly; the existing test
  count does not regress.
