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
- [x] **T3.2** Add safety-net cleanup for stale preview overlay registries after the winning preview item is installed, preserving active and in-flight preview registries.

## Task and resource lifetime follow-up

- [x] **T5.1** Break stored publish observation/polling Task cycles and cancel both tasks in `PublishPanelState.deinit`.
- [x] **T5.2** Use weak UI/model captures for fire-and-forget Task launch sites while preserving strong model/session/manager captures for stop, landing, replay save, and cleanup completion.
- [x] **T5.3** Cancel silence detection, coalesced commit, and loudness tasks in `EditorModel.deinit`.
- [x] **T5.4** Remove the region picker key monitor during unexpected controller deallocation.
- [x] **T5.5** Avoid implicit `ReplayBufferManager` capture when scheduling ring updates and appends.

## Main-actor and invalid-input hardening

- [x] **T6.1** Move recording disk-capacity resource-value reads off the main actor.
- [x] **T6.2** Clamp fallback audio sample timing to a valid timescale for zero, non-finite, negative, and out-of-range sample rates.
- [x] **T6.3** Reject zero-sized source pixel buffers before frame-scaling division.
- [x] **T6.4** Bound the padded-background image cache and retain the newest entry after overflow eviction.

## Verification

- [x] **T4.1** `xcodebuild` (Debug, macOS) green.
- [x] **T4.2** Existing tests pass.
- [x] **T4.3** Memory-pressure regression coverage verifies render-cache memory purge, CIContext purge, overlay source cache purge, registry cleanup, Lottie purge, alpha-video purge, and render-cache disk-spill preservation.
- [x] **T4.4** PR review follow-up confirms `PaddedBackgroundRenderer` eviction, logger subsystem consistency, removal of unused overlay cache count state, and documented overlay purge lock ordering.
- [x] **T4.5** App-target tests cover fallback audio sample timing for invalid rates and source-duration precedence.
- [x] **T4.6** App-target tests cover padded-background cache overflow and coordinated memory-pressure purge.
