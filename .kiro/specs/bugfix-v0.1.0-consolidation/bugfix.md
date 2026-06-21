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

### B10 — Thumbnail tasks strong-capture `self`

`EditorModel.swift:137` and `EditorModel+Persistence.swift:315` launch `Task { await self.generateThumbnail(for: item) }` with a strong capture of `self`. If the user closes the window, the `EditorModel` is kept alive until all thumbnail tasks finish.

- **Fix**: Use `[weak self]` in both thumbnail `Task` closures.

### B11 — `endObserver` watches all players

`EditorModel.swift:79-85` registers the end-of-playback observer with `object: nil`, meaning any `AVPlayerItem.didPlayToEndTimeNotification` from any player sets `isPlaying = false`. Currently harmless (single player), but fragile.

- **Fix**: Filter in the closure to only respond when the notification's object matches `player.currentItem`.

### B12 — `wasPlaying` race in `rebuild()` (review follow-up)

`EditorModel.swift:742` captured `isPlaying` into a `wasPlaying` flag before the `await CompositionBuilder.build(...)`. If the user pauses during the async build, the old `wasPlaying=true` would override their pause and resume playback.

- **Fix**: Remove the captured flag; check live `isPlaying` after the seek instead. If the user paused during the build, `isPlaying` is `false` and playback won't resume.

### B13 — Repetitive `isExporting` reset (review follow-up)

`export(to:)` manually reset `isExporting = false` on every early return path and in the `catch` block, in addition to a `defer` on the success path. Adding a new early return could forget the reset.

- **Fix**: Restructure with a single `defer { isExporting = false; exportProgress = nil }` at the top of the function body, before any `do` block. The inner `defer` on the success path only cancels the progress task.

### B14 — Unconditional selection clear (review follow-up)

`removeMedia` unconditionally set `selectedClipID = nil` and `selectedTransitionClipID = nil`. If the removed media item was unrelated to the currently selected clip, the selection was unnecessarily lost.

- **Fix**: Only clear `selectedClipID`/`selectedTransitionClipID` if the selected clip/transition was orphaned by the removal (i.e. `clip(for:)` returns nil after orphan cleanup).

### U1 — Media bin context menu missing "Remove"

`MediaBinView`'s context menu only offered "Add to Timeline". There was no way to remove a media item from the project via the bin — users had to know about right-click menus in the timeline.

- **Fix**: Add "Remove from Project" with `.destructive` role to the context menu, calling `model.removeMedia(itemID:)`.

### U2 — Status bar uses iOS-style capsule overlay

The status bar was rendered as a `Capsule`-shaped overlay at the bottom of the window, which is an iOS pattern. macOS status bars (e.g., Xcode, Safari, Finder) typically span the full width as a thin bar.

- **Fix**: Change from `.overlay` with capsule to `.safeAreaInset(edge: .bottom)` with a full-width `.ultraThinMaterial` bar.

### U3 — `AnyShapeStyle(.selection)` wrapper unnecessary

`MediaRow` used `AnyShapeStyle(.selection)` for the selected background. The `AnyShapeStyle` type-erasure wrapper was unnecessary on macOS 26+ where `Color` directly accepts the standard system selection color.

- **Fix**: Replace with `Color(.selectedContentBackgroundColor)`.
