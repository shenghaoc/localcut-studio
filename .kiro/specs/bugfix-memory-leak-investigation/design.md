# Design: Memory Leak Bugfix

## Approach

### 1. Reduce cache budgets (F1, F2, F5)

Immediate relief by reducing default cache sizes:

| Cache | Current | Proposed | Rationale |
|-------|---------|----------|-----------|
| LottieFrameSource.maxCachedBytes | 256 MB | 64 MB | 4× reduction; still holds ~8 frames at 1080p / ~2 frames at 4K |
| RenderCache.defaultByteBudget | 256 MiB | 128 MiB | 2× reduction; still holds ~16 frames at 1080p |
| RenderCache.defaultDiskByteBudget | 1 GiB | 512 MiB | 2× reduction |
| AlphaVideoSource.maxCachedFrames | 8 | 4 | 2× reduction; still smooth for typical overlays |

### 2. Add memory pressure handling (F3, F6, F7, F9)

Create a `MemoryPressureHandler` that:
- Retains a `DispatchSourceMemoryPressure` registered for warning and critical events
- On pressure: calls eviction methods on all cache singletons
- Singleton caches get `purge()`, `purgeMemory()`, or source-specific purge methods

Affected singletons:
- `RenderCache.shared` — add `purgeMemory()` so pressure clears RAM without disk I/O
- `LUTCache.shared` — add `purge()`
- `CaptionRasterer` (via `EffectCompositor.sharedCaptionRasterer`) — add `purge()`
- `EffectCompositor.contextCache` — add `purgeContextCache()`
- `EffectCompositor` overlay source registries — keep registered sources but ask each source to drop decoded frames
- `PaddedBackgroundRenderer` — reuse its existing `purgeCache()` entry point

### 3. Audit overlay source registry cleanup (F4)

Review all exit paths from `PreviewRebuildCoordinator.rebuild()`, cover generation, and `RenderQueue` to ensure `EffectCompositor.releaseOverlaySources()` is called. Add a safety-net cleanup after the winning preview item is installed so stale preview registries are released while active, in-flight, and transient export/cover registries are preserved.

### 4. CIContext cache eviction (F3)

Add a `purgeContextCache()` method to the `contextCache` lock that removes all cached contexts. Called by the memory pressure handler.

### 5. Task and resource lifetime hardening (F11, F12)

- Use weak captures for UI/model owners in escaping tasks that do not require ownership extension.
- Keep critical cleanup dependencies such as `ProgramSession`, `EditorModel`, and `ReplayBufferManager` strongly captured until stop, landing, or cleanup completes.
- Avoid promoting weak UI-state captures to strong references outside long-lived observation and polling loops.
- Cancel stored tasks in owner `deinit` methods and remove the region picker event monitor on both normal completion and unexpected deallocation.

### 6. Main-actor and invalid-input guards (F13, F14)

- Run synchronous disk-capacity resource-value reads in a detached task, then publish the result on the main actor.
- Derive fallback audio sample duration through a testable helper that clamps non-finite, non-positive, and out-of-range sample rates to a valid `CMTimeScale`.
- Reject zero-sized source pixel buffers before computing scale factors.

### 7. Bound the padded-background cache (F15)

Keep at most eight distinct background-image entries. When insertion exceeds the cap, clear the old cache and retain the newly requested image so the current frame does not immediately reload it. Continue purging the cache on document close and coordinated memory pressure.

## Non-goals

- Reducing `MediaItem` asset retention (F8) — these are user-imported media and must remain accessible
- Changing the `ScopeSampler` sampling model — its samples are already bounded by the diagnostics ring-buffer model and need separate investigation before changing
- Changing Program Mode, replay-buffer, publish, import, or export user-facing workflows beyond their task/resource lifetime behavior
