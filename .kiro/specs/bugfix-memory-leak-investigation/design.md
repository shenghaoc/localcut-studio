# Design: Memory Leak Bugfix

## Approach

### 1. Reduce cache budgets (F1, F2, F5)

Immediate relief by reducing default cache sizes:

| Cache | Current | Proposed | Rationale |
|-------|---------|----------|-----------|
| LottieFrameSource.maxCachedBytes | 256 MB | 64 MB | 4× reduction; still holds ~16 frames at 1080p |
| RenderCache.defaultByteBudget | 256 MiB | 128 MiB | 2× reduction; still holds ~16 frames at 1080p |
| RenderCache.defaultDiskByteBudget | 1 GiB | 512 MiB | 2× reduction |
| AlphaVideoSource.maxCachedFrames | 8 | 4 | 2× reduction; still smooth for typical overlays |

### 2. Add memory pressure handling (F3, F6, F7, F9)

Create a `MemoryPressureHandler` that:
- Listens for `ProcessInfo.processInfo.isLowPowerModeEnabled` changes
- Listens for `NSApplication.didReceiveMemoryWarning` (via NotificationCenter)
- On pressure: calls eviction methods on all cache singletons
- Singleton caches get `purge()` or `removeAll()` methods

Affected singletons:
- `RenderCache.shared` — already has `removeAll()`
- `LUTCache.shared` — add `purge()`
- `CaptionRasterer` (via `EffectCompositor.sharedCaptionRasterer`) — add `purge()`
- `EffectCompositor.contextCache` — add `purgeAll()`
- `ScopeSampler.shared` — verify samples are overwritten, not accumulated

### 3. Audit overlay source registry cleanup (F4)

Review all exit paths from `PreviewRebuildCoordinator.rebuild()` and `RenderQueue` to ensure `EffectCompositor.releaseOverlaySources()` is called. Add a safety-net cleanup at the start of each rebuild.

### 4. CIContext cache eviction (F3)

Add a `purgeAll()` method to the `contextCache` lock that removes all cached contexts. Called by the memory pressure handler.

## Non-goals

- Reducing `MediaItem` asset retention (F8) — these are user-imported media and must remain accessible
- Changing the `ScopeSampler` sampling model — needs investigation first
