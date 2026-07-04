# Tasks: Memory Leak Bugfix

> Status: **Implemented**.

## Cache budget reductions

- [x] **T1.1** Reduce `LottieFrameSource.maxCachedBytes` from 256 MB to 64 MB.
- [x] **T1.2** Reduce `RenderCache.defaultByteBudget` from 256 MiB to 128 MiB.
- [x] **T1.3** Reduce `RenderCache.defaultDiskByteBudget` from 1 GiB to 512 MiB.
- [x] **T1.4** Reduce `AlphaVideoSource.maxCachedFrames` from 8 to 4.

## Memory pressure handling

- [x] **T2.0** Add `RenderCache.purgeMemory()` so pressure eviction frees RAM without deleting disk-spill files.
- [x] **T2.1** Add `purge()` method to `LUTCache`.
- [x] **T2.2** Add `purge()` method to `CaptionRasterer` / expose via `EffectCompositor`.
- [x] **T2.3** Add `purgeContextCache()` method to `EffectCompositor.contextCache`.
- [x] **T2.4** Create `MemoryPressureHandler` that retains a `DispatchSourceMemoryPressure` and calls purge on pressure-aware caches.
- [x] **T2.5** Wire `MemoryPressureHandler` into app lifecycle (e.g., `AppDelegate` or `App.init`).
- [x] **T2.6** Include `PaddedBackgroundRenderer.purgeCache()` in memory-pressure eviction.

## Overlay registry audit

- [x] **T3.1** Audit all `registerOverlaySources` call sites; verify matching `releaseOverlaySources` on every exit path.
- [x] **T3.2** Add safety-net cleanup for stale preview overlay registries at the start of each preview rebuild.

## Verification

- [x] **T4.1** `xcodebuild` (Debug, macOS) green.
- [x] **T4.2** Existing tests pass.
- [x] **T4.3** Memory-pressure regression coverage verifies render-cache memory purge, CIContext purge, overlay source cache purge, registry cleanup, Lottie purge, alpha-video purge, and render-cache disk-spill preservation.
- [x] **T4.4** PR review follow-up confirms `PaddedBackgroundRenderer` eviction, logger subsystem consistency, removal of unused overlay cache count state, and documented overlay purge lock ordering.
