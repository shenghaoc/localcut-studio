# Tasks: Memory Leak Bugfix

> Status: **Implemented**.

## Cache budget reductions

- [x] **T1.1** Reduce `LottieFrameSource.maxCachedBytes` from 256 MB to 64 MB.
- [x] **T1.2** Reduce `RenderCache.defaultByteBudget` from 256 MiB to 128 MiB.
- [x] **T1.3** Reduce `RenderCache.defaultDiskByteBudget` from 1 GiB to 512 MiB.
- [x] **T1.4** Reduce `AlphaVideoSource.maxCachedFrames` from 8 to 4.

## Memory pressure handling

- [x] **T2.1** Add `purge()` method to `LUTCache`.
- [x] **T2.2** Add `purge()` method to `CaptionRasterer` / expose via `EffectCompositor`.
- [x] **T2.3** Add `purgeAll()` method to `EffectCompositor.contextCache`.
- [x] **T2.4** Create `MemoryPressureHandler` that listens for memory warnings and calls purge on all singletons.
- [x] **T2.5** Wire `MemoryPressureHandler` into app lifecycle (e.g., `AppDelegate` or `App.init`).

## Overlay registry audit

- [x] **T3.1** Audit all `registerOverlaySources` call sites; verify matching `releaseOverlaySources` on every exit path.
- [x] **T3.2** Add safety-net cleanup for stale preview overlay registries at the start of each preview rebuild.

## Verification

- [x] **T4.1** `xcodebuild` (Debug, macOS) green.
- [x] **T4.2** Existing tests pass.
- [ ] **T4.3** Manual verification: open a project with overlays, edit for 10+ minutes, verify memory stays bounded.
