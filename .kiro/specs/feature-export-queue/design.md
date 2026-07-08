# Design: Export Presets + Render Queue (P17 / P24 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 39 (vertical-first
> finishing — 9:16 / 1:1 / 4:5 safe zones + covers) and a foundation for later
> vertical / social finishing phases.

## Goal

Make export a *queued, recipe-driven* operation instead of a single-shot menu
command:

1. A **preset model** that encodes target *container × video codec × aspect ×
   bitrate × frame-rate × audio* in one Codable value, so the editor can choose
   "YouTube 1080p" vs "TikTok 9:16" without re-entering panels.
2. A **render queue** that owns a list of jobs (preset + output URL + project
   snapshot) and runs them serially in the background, with cancellation,
   per-job progress, and a one-line `os_log` line per status transition.
3. **Persistence** so a relaunch restores the queue (queued jobs continue;
   interrupted in-flight jobs surface as resumable).
4. A **Renders panel** in the inspector with one-tap "Add to queue" buttons next
   to every built-in preset and a queue list with status pills + cancel
   buttons. The existing menu/toolbar Export action becomes a shortcut for
   "queue with the default preset and start immediately".

## Preset model (`LocalCut Studio/ExportPresets.swift`)

```swift
nonisolated struct AudioConfig: Codable, Hashable, Sendable {
    var codec: String          // AVAudioFormatID raw, stringified — kAudioFormatMPEG4AAC, kAudioFormatLinearPCM
    var bitrate: Int           // bits per second; PCM ignores it
    var sampleRate: Int        // Hz, typically 48000
    var channels: Int          // 1 or 2
}

nonisolated enum ExportAspect: String, Codable, Hashable, Sendable, CaseIterable {
    case widescreen     // 16:9
    case vertical       // 9:16
    case square         // 1:1
    case portrait4x5    // 4:5
    case cinema21x9     // 21:9
    var ratio: CGSize { ... }
}

nonisolated enum ExportBitrateBracket: String, Codable, Hashable, Sendable, CaseIterable {
    case low, standard, high, max
    /// Heuristic bits-per-second target for a render size, used by the
    /// AVAssetWriter fallback when AVAssetExportSession has no matching preset.
    func bitsPerSecond(for renderSize: CGSize) -> Int { ... }
}

nonisolated struct ExportPreset: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String                 // "YouTube 1080p"
    var containerFormat: String      // AVFileType.rawValue — "com.apple.quicktime-movie"
    var videoCodec: String           // AVVideoCodecType.rawValue — "avc1" / "hvc1" / "apch"
    var aspect: ExportAspect
    var targetSize: CGSize           // explicit pixel size; aspect-implied unless overridden
    var bitrate: ExportBitrateBracket
    var frameRate: Double?           // nil ⇒ inherit project frame rate
    var audioConfig: AudioConfig
}
```

`BuiltInExportPresets.all` ships **six** vetted presets:

| Name | Container | Codec | Aspect | Size | Bitrate | Audio |
|---|---|---|---|---|---|---|
| YouTube 1080p | `.mp4` | `.h264` | 16:9 | 1920×1080 | standard | AAC 192k |
| YouTube 4K | `.mp4` | `.hevc` | 16:9 | 3840×2160 | high | AAC 256k |
| Instagram 9:16 | `.mp4` | `.h264` | 9:16 | 1080×1920 | standard | AAC 128k |
| TikTok 9:16 | `.mp4` | `.h264` | 9:16 | 1080×1920 | standard | AAC 128k |
| ProRes 4K | `.mov` | `.proRes422HQ` | 16:9 | 3840×2160 | max | LPCM 48 kHz |
| Web 720p | `.mp4` | `.h264` | 16:9 | 1280×720 | low | AAC 128k |

### Codec × container validity

Every built-in pair must be playable by AVFoundation's writers. The static
allow-list `ExportPreset.isSupportedCombination(container:codec:)` is the gate
the queue checks before scheduling a job and the test suite exercises against
every built-in.

| Container | Codecs allowed |
|---|---|
| `.mov` | `.h264`, `.hevc`, `.proRes422`, `.proRes422HQ`, `.proRes422LT`, `.proRes422Proxy`, `.proRes4444` |
| `.mp4` | `.h264`, `.hevc` |
| `.m4v` | `.h264`, `.hevc` |

Unsupported combos (e.g. ProRes inside `.mp4`) are rejected at enqueue with a
`.unsupportedCombination` error so the queue never starts an export the writer
can't satisfy.

## Queue engine (`LocalCut Studio/RenderQueue.swift`)

```swift
nonisolated enum QueueJobStatus: String, Codable, Hashable, Sendable {
    case queued, running, completed, cancelled, failed
}

nonisolated struct QueueJob: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var preset: ExportPreset
    var outputBookmark: Data       // security-scoped bookmark to the destination
    var outputDisplayName: String  // for UI; the bookmark drives the actual write
    var projectSnapshot: ProjectDocument
    var status: QueueJobStatus
    var progress: Double           // 0...1 for the currently-running job
    var errorMessage: String?
}

@Observable
@MainActor
final class RenderQueue {
    private(set) var jobs: [QueueJob]
    var currentJobID: UUID?
    var totalProgress: Double      // weighted by remaining job count
    var isRunning: Bool
    var statusMessage: String?

    func enqueue(_ job: QueueJob)
    func cancel(jobID: UUID)
    func clearCompleted()
    func start()                   // idempotent; runs only if not already running
    func stop()                    // cancels current job and pauses the runner
}
```

**Execution.** A single internal `Task` is the runner. It pulls the next
`.queued` job, marks it `.running`, builds the composition from the snapshot,
chooses the export path, and awaits completion. On finish (success / failure /
cancellation) it updates status + persists, then loops.

Runner ownership is keyed by a private token, not only the observable
`isRunning` flag. Cleanup only clears the token it created; if a new job is
enqueued while the old runner is draining, cleanup clears the old task and
immediately restarts the queue. `stop()` suppresses that automatic restart so
queued jobs remain paused when the user explicitly stops the runner.

**Source-bookmark resolution.** Resolving source-media bookmarks (which may
touch sleeping drives or network shares) happens off MainActor via
`Task.detached`; only `startAccessingSecurityScopedResource()` and
`MediaItem` assembly stay on MainActor. A `false` return from
`startAccessing` counts as a missing source, failing the job cleanly
rather than producing a silently partial export. If a source bookmark resolves
with `bookmarkDataIsStale == true`, the queue creates a fresh security-scoped
bookmark and stores it back into the job snapshot before persisting.

**Writer pump.** The `AVAssetWriter` fallback uses
`input.markAsFinished()` to signal exhaustion. Note:
`stopRequestingMediaData()` does **not** exist on `AVAssetWriterInput` —
it is an `AVAssetReaderOutput` API only. The `ResumeBox` pattern handles
any in-flight callback race after `markAsFinished()`.

**Path selection.** Each job picks one of two paths at start:

1. **`AVAssetExportSession` (preferred).** A preset name table maps
   `(codec, size, bracket)` → `AVAssetExportPresetName`. Covers every built-in
   preset shipped today.
2. **`AVAssetWriter` (fallback).** Used when no `AVAssetExportSession` preset
   matches. Builds video / audio settings dicts from the `ExportPreset` and
   runs a `AVAssetReader` → `AVAssetWriter` pipeline. The path is plumbed so
   a future user-defined preset (custom HEVC at 720p, for example) lands here
   instead of failing.

**Cancellation.** `cancel(jobID:)` sets a flag and (if the job is in flight)
calls `AVAssetExportSession.cancelExport()` or marks the writer's session as
cancelled. The runner observes the flag at each await suspension point and
exits the per-job function, which transitions the job to `.cancelled` and
returns to the loop.

**Progress.** Inside the export path the runner subscribes to the session's
`states(updateInterval:)` async sequence and writes `progress` into the active
`QueueJob`. `totalProgress` is `(completed + active.progress) / total`.

**Logging.** A single `Logger(subsystem: "com.shenghaoc.LocalCutStudio",
category: "render-queue")` emits one line per state transition:

```
job 9f0… enqueued — YouTube 1080p
job 9f0… running — output: /Users/me/Movies/clip.mp4
job 9f0… completed in 12.3s
job 9f0… cancelled
job 9f0… failed — Output already exists
```

No structured payloads — the line is the audit trail.

## Persistence

`~/Library/Application Support/LocalCut Studio/queue.json` holds a versioned
`RenderQueueDoc { version: 1, jobs: [QueueJob] }`. App Sandbox grants the
container's Application Support directly, so no security-scoped bookmark is
needed for the queue file itself.

**Output URLs do require security-scoped bookmarks** (the user picked them
through `NSSavePanel`). Each job's `outputBookmark` is created at enqueue with
`.withSecurityScope`; the runner re-resolves it at job start with
`startAccessingSecurityScopedResource()` (balanced by a `stopAccessing…` in
the per-job `defer`). A stale-but-resolvable output bookmark is refreshed in
place during reveal, load reconciliation, or job start, then persisted with the
next queue write.

`RenderQueue` keeps production bookmark resolution private but lets tests inject
an `@Sendable` output-bookmark resolver through the initializer. Production
queues use the real security-scoped bookmark APIs by default; deterministic
tests can return a known resolution result without depending on macOS bookmark
timing or parallel test load.

**Resume.** On `RenderQueue.load()`:

- `.queued` jobs stay queued and start when `start()` runs.
- `.running` jobs reset to `.queued` — `AVAssetExportSession` has no resume
  API; the cleanest "resume" is to restart from scratch with the same
  snapshot + output URL. The `errorMessage` is cleared.
- `.completed`, `.failed`, `.cancelled` jobs are preserved as terminal entries
  for history; the UI groups them under "Recent".
- A job whose `outputBookmark` no longer resolves transitions to
  `.failed("Output destination unavailable")` rather than silently dropping —
  the user keeps the row to retry against a new destination.
- A job whose `outputBookmark` resolves as stale receives a replacement
  security-scoped bookmark and remains queued.

Save is triggered after every transition (atomic write); JSON is small enough
that this isn't a perf concern. Each write is chained behind the previous
detached write task so rapid state transitions cannot land on disk out of
order. If the queue-file location cannot be created or the atomic write fails,
`RenderQueue` logs the error and updates `statusMessage` so the user sees that
the current queue state was not saved.

## UI (`LocalCut Studio/RenderQueueInspectorView.swift`)

A new `Renders` section in the inspector, beside `Captions`:

```
▾ Renders
  [Built-in presets]
    • YouTube 1080p     [Add to Queue…]
    • YouTube 4K        [Add to Queue…]
    • Instagram 9:16    [Add to Queue…]
    • TikTok 9:16       [Add to Queue…]
    • ProRes 4K         [Add to Queue…]
    • Web 720p          [Add to Queue…]

  [Queue]
    [═══════════════░░░░░░░░] 62%          ← totalProgress (visible while running)
    • clip.mp4         [running 42%]   [⎯]   ← cancel
    • clip2.mov        [queued]         [⎯]
    • clip-old.mp4     [completed]
```

`[Add to Queue…]` opens a save-panel scoped to the preset's container, creates
the job's security-scoped bookmark, snapshots the project, and enqueues. The
queue starts automatically.

**Existing Export action** (toolbar + File menu) becomes
`exportWithDefaultPreset()` — picks the first built-in preset (YouTube 1080p)
and routes through the same enqueue path. Same effect as before for a user
who hasn't discovered the queue panel.

## Trade-offs

- **Snapshot per job, not a live project ref.** A queued export is independent
  of subsequent edits, mirroring how the existing `export(to:)` already holds
  security-scoped access to the source files for the duration of the write.
  The snapshot is the existing `ProjectDocument` (already Codable), so no new
  schema enters the queue payload.
- **Serial, not parallel.** Parallel renders fight for the GPU and the
  encoder; serial is the right default. A future "render concurrency" knob
  can be added without breaking the data layer.
- **Two paths, one queue.** Routing through `AVAssetExportSession` for built-ins
  reuses Apple's tuned presets; the writer path keeps the door open for
  user-defined presets without forcing every export through the writer.
- **One log line per transition.** Anything richer (per-frame metrics, codec
  parameters) belongs in the future Diagnostics panel (P25). The audit trail
  here is "did this job start / finish / fail and when".

## Risks

- **AVAssetExportSession preset matrix is finite.** A user-defined preset that
  doesn't match any `AVAssetExport…` constant must route to the writer or be
  rejected. The MVP rejects it; the writer path is a stub awaiting a follow-up.
  All six built-ins map to known `AVAssetExport…` presets, so the MVP ships
  without exercising the stub.
- **Stale output bookmark.** `Documents/` or `Movies/` can move; the resume
  path catches this and transitions to `.failed` rather than crashing.
- **A queue.json from a newer version** must not lose unknown fields on save.
  The version guard refuses to overwrite if the on-disk version is greater
  than the build's `currentVersion`, mirroring the project-document rule.

## Non-goals

- Distributed / remote rendering.
- Per-frame progress (the section progress comes from
  `AVAssetExportSession.states`).
- Codec parameter sliders (CRF, GOP, etc.) — that's a future "advanced preset"
  spec; the built-ins encode opinionated choices.
- Render farm coordination.
- Sidecar metadata (chapters, captions burned-in) beyond what the existing
  composition already emits.
