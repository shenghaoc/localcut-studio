# Bugfix: v0.1.0 Consolidation

Fixes identified during the pre-release hardening review against AGENTS.md review guidelines (P0/P1 checklist) and macOS 27 / Swift 6 compliance scan.

## Bugs

### B1 — Security-scoped resource leak on successful import

`importMedia(urls:)` in `EditorModel` calls `startAccessingSecurityScopedResource()` but only calls `stopAccessingSecurityScopedResource()` on the error path. Successful imports retain access for the session with no release mechanism, leaking security-scoped assertions as files accumulate.

- **Fix**: Stop security-scoped access when the corresponding `MediaItem` is removed from the project. Add `removeMedia(itemID:)` that calls `stopAccessingSecurityScopedResource()` before removal.

### B2 — Force-unwrap in `trimClip`

`EditorModel.swift:449` force-unwraps `sorted.firstIndex(where: { $0.id == id })!`. While the clip ID is guaranteed present given the guard on line 442, the `!` introduces a crash risk under future refactoring.

- **Fix**: Replace with `guard let sortedIndex`.

### B3 — `CGColorSpace.sRGB` force-unwrap

`EffectCompositor.swift:60` force-unwraps `CGColorSpace(name: CGColorSpace.sRGB)!`. A system color space is nearly guaranteed to exist, but a nil value would crash every compositing frame and the `CIContext` initializer that depends on it.

- **Fix**: Use `guard let` with `CGColorSpaceCreateDeviceRGB()` fallback.

### B4 — iOS-specific build settings in macOS target

The macOS target in `project.pbxproj` carries `IPHONEOS_DEPLOYMENT_TARGET`, `UIApplicationSceneManifest_Generation`, `UILaunchScreen_Generation`, `UIStatusBarStyle`, and `UIInterfaceOrientation` keys — residuals from the cross-platform template.

- **Fix**: Remove iOS-specific keys from the macOS target build settings.

### B5 — Timeline clips lack accessibility

Clip blocks in `TimelineView` have no `accessibilityLabel` or accessibility traits. VoiceOver users cannot select, trim, or navigate clips. Transition glyphs already have labels (added in the transitions feature).

- **Fix**: Add `accessibilityLabel` with the clip's media name and `.isButton` trait to each clip block.

### B6 — `LUTCache` uses legacy `NSLock`

`LUTCache` uses `NSLock` + `@unchecked Sendable` + `nonisolated(unsafe)`. `OSAllocatedUnfairLock` (macOS 13+) is the modern Swift 6 primitive for thread-safe caches and offers better performance.

- **Fix**: Replace with `OSAllocatedUnfairLock(initialState:)` using `withLock`; remove `@unchecked` since the lock + `Sendable` inner struct make the class implicitly `Sendable`.

### B7 — Export race (TOCTOU)

`export(to:)` sets `isExporting = true` at line 802 — after the first `await` at line 788. A second call can slip past the `guard !isExporting` while the first is suspended at the `await`.

- **Fix**: Move `isExporting = true` before the first `await`. Add `isExporting = false` on the early-return paths before the `defer`.

### B8 — Rebuild kills playback

`rebuild()` replaces the `AVPlayerItem` but never checks `isPlaying` to resume. After any edit, playback silently stops.

- **Fix**: Capture `wasPlaying` before the rebuild; call `player.play()` after the seek if it was true.

### B9 — Silent LUT bookmark failure

`applyLUT` returns nil when the bookmark is stale (line 279). The `?? result` at the call site keeps the pipeline running but silently drops the effect. The user sees the LUT in the inspector but it renders as a no-op.

- **Fix**: Log `os_log(.error, ...)` so the failure is at least observable in the system log.
