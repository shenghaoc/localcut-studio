# Tasks: Memory Leak Bugfix

> Status: **Proposed**.

## Cache budget reductions

- [ ] **T1.1** Reduce `LottieFrameSource.maxCachedBytes` from 256 MB to 64 MB.
- [ ] **T1.2** Reduce `RenderCache.defaultByteBudget` from 256 MiB to 128 MiB.
- [ ] **T1.3** Reduce `RenderCache.defaultDiskByteBudget` from 1 GiB to 512 MiB.
- [ ] **T1.4** Reduce `AlphaVideoSource.maxCachedFrames` from 8 to 4.

## Memory pressure handling

- [ ] **T2.1** Add `purge()` method to `LUTCache`.
- [ ] **T2.2** Add `purge()` method to `CaptionRasterer` / expose via `EffectCompositor`.
- [ ] **T2.3** Add `purgeAll()` method to `EffectCompositor.contextCache`.
- [ ] **T2.4** Create `MemoryPressureHandler` that listens for memory warnings and calls purge on all singletons.
- [ ] **T2.5** Wire `MemoryPressureHandler` into app lifecycle (e.g., `AppDelegate` or `App.init`).

## Overlay registry audit

- [ ] **T3.1** Audit all `registerOverlaySources` call sites; verify matching `releaseOverlaySources` on every exit path.
- [ ] **T3.2** Add safety-net `releaseOverlaySources` at start of each composition rebuild.

## Verification

- [ ] **T4.1** `xcodebuild` (Debug, macOS) green.
- [ ] **T4.2** Existing tests pass.
- [ ] **T4.3** Manual verification: open a project with overlays, edit for 10+ minutes, verify memory stays bounded.
