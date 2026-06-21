# Tasks: v0.1.0 Consolidation

> Status: **In progress**.

- [x] **B1** Fix security-scoped resource leak: add `removeMedia(itemID:)` with proper `stopAccessingSecurityScopedResource()`.
- [x] **B2** Fix force-unwrap in `trimClip`: replace `!` with `guard let`.
- [x] **B3** Fix `CGColorSpace.sRGB` force-unwrap: `guard let` with device RGB fallback.
- [x] **B4** Clean iOS-specific build settings from macOS target.
- [x] **B5** Add accessibility labels to timeline clip blocks.
- [x] **B6** Migrate `LUTCache` from `NSLock` to `OSAllocatedUnfairLock`.

## Verification

- [x] **V1** `xcodebuild` Debug/macOS clean build, zero warnings.
- [x] **V2** All 50 existing tests pass (no regressions).
