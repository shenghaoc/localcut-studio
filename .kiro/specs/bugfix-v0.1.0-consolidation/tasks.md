# Tasks: v0.1.0 Consolidation

> Status: **Complete**.

- [x] **B1** Fix security-scoped resource leak: add `removeMedia(itemID:)` with proper `stopAccessingSecurityScopedResource()`.
- [x] **B2** Fix force-unwrap in `trimClip`: replace `!` with `guard let`.
- [x] **B3** Fix `CGColorSpace.sRGB` force-unwrap: `guard let` with device RGB fallback.
- [x] **B4** Clean iOS-specific build settings from macOS target.
- [x] **B5** Add accessibility labels to timeline clip blocks.
- [x] **B6** Migrate `LUTCache` from `NSLock` to `OSAllocatedUnfairLock`, remove `@unchecked Sendable`.
- [x] **B7** Fix export race: set `isExporting = true` before first `await` in `export(to:)`.
- [x] **B8** Fix rebuild killing playback: capture `isPlaying` and resume after seek.
- [x] **B9** Fix silent LUT failure: log `os_log(.error, ...)` when stale bookmark drops effect.
- [x] **B10** Fix thumbnail Task strong-capture `self`: use `[weak self]`.
- [x] **B11** Fix `endObserver` scope: filter notifications to match `player.currentItem`.
- [x] **B12** Fix `wasPlaying` race: check live `isPlaying` instead of captured flag.
- [x] **B13** Fix repetitive `isExporting` reset: single `defer` at top of `export(to:)`.
- [x] **B14** Fix unconditional selection clear: only clear if clip/transition orphaned.

## Verification

- [x] **V1** `xcodebuild` Debug/macOS clean build, zero warnings.
- [x] **V2** All 71 existing tests pass (no regressions).
