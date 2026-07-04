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

Review all exit paths from `PreviewRebuildCoordinator.rebuild()`, cover generation, and `RenderQueue` to ensure `EffectCompositor.releaseOverlaySources()` is called. Add a safety-net cleanup at the start of each preview rebuild for stale preview registries while preserving transient export/cover registries.

### 4. CIContext cache eviction (F3)

Add a `purgeContextCache()` method to the `contextCache` lock that removes all cached contexts. Called by the memory pressure handler.

## Non-goals

- Reducing `MediaItem` asset retention (F8) — these are user-imported media and must remain accessible
- Changing the `ScopeSampler` sampling model — its samples are already bounded by the diagnostics ring-buffer model and need separate investigation before changing
