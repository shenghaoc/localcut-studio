# Bugfix: Memory Leak Investigation

## Problem

Users experience "Your system has run out of application memory" warnings during extended editing sessions. Investigation reveals multiple unbounded or excessively large caches that accumulate without proper eviction or memory pressure handling.

## Root Causes

### F1. LottieFrameSource: 256 MB cache per overlay (CRITICAL)
- **File**: `LocalCut Studio/LottieFrameSource.swift`
- **Line**: `private static let maxCachedBytes = 256 * 1024 * 1024`
- Each Lottie overlay caches up to 256 MB of decoded CIImage frames
- 3 overlays = 768 MB just in Lottie caches

### F2. RenderCache: 256 MiB memory + 1 GiB disk (CRITICAL)
- **File**: `LocalCut Studio/RenderCache.swift`
- `defaultByteBudget = 256 * 1024 * 1024` (256 MiB in-memory)
- `defaultDiskByteBudget = 1024 * 1024 * 1024` (1 GiB on disk)
- Singleton (`RenderCache.shared`) with LRU eviction but very large budget

### F3. EffectCompositor: CIContext cache never cleared (HIGH)
- **File**: `LocalCut Studio/EffectCompositor.swift`
- `private static let contextCache` caches CIContext per color space
- CIContexts hold GPU resources and internal caches (~50-100 MB each)
- Never released, even on memory pressure

### F4. EffectCompositor: Overlay source registries (HIGH)
- **File**: `LocalCut Studio/EffectCompositor.swift`
- `overlaySourceRegistries: [UUID: [UUID: any OverlayFrameSource]]`
- Static dictionary accumulates if `releaseOverlaySources` missed on any exit path
- Each source holds decoded frames

### F5. AlphaVideoSource: 8-frame CIImage cache (HIGH)
- **File**: `LocalCut Studio/AlphaVideoSource.swift`
- `maxCachedFrames = 8`
- Each 4K alpha frame ~33 MB → 264 MB per overlay

### F6. LUTCache: Singleton, no eviction (MEDIUM)
- **File**: `LocalCut Studio/EffectCompositor.swift`
- `nonisolated static let shared = LUTCache()`
- Caches LUT data by bookmark, no eviction policy

### F7. CaptionRasterer: Singleton, no eviction (MEDIUM)
- **File**: `LocalCut Studio/EffectCompositor.swift`
- `private static let sharedCaptionRasterer = CaptionRasterer()`
- Caches rasterized caption frames, only cleared on color space change

### F8. MediaItem: Retains AVURLAsset + CGImage permanently (MEDIUM)
- **File**: `LocalCut Studio/Models.swift`
- Each MediaItem holds `AVURLAsset` + `thumbnail: CGImage?` for project lifetime

### F9. No system memory pressure handling (MEDIUM)
- No listener for `NSApplication.didReceiveMemoryWarning`
- No coordinated cache eviction across singletons

### F10. PaddedBackgroundRenderer: Singleton CGImage cache not pressure-aware (MEDIUM)
- **File**: `LocalCut Studio/PaddedBackgroundRenderer.swift`
- Cached padded-background `CGImage` entries are purged on document close but previously survived memory-pressure eviction.

### F11. Long-lived Task closures retain panel state (HIGH)
- **Files**: `PublishPanelState.swift`, `ProgramPanelState.swift`, and Task-launching model/view call sites
- Stored publish observation and polling tasks promoted weak captures to strong references for their full loops, creating `state -> Task -> state` cycles.
- Fire-and-forget tasks also retained view/model owners longer than their UI lifetime unless the operation explicitly required a strong cleanup dependency.

### F12. Owned tasks and event monitors miss teardown (HIGH)
- **Files**: `EditorModel.swift`, `PublishPanelState.swift`, `RegionCapturePicker.swift`
- Silence detection, coalesced undo commits, loudness analysis, publish observation, and publish polling tasks were not all cancelled by their owners.
- The region picker removed its local key monitor on normal completion but lacked a deinitialization fallback.

### F13. Recording monitor performs synchronous volume I/O on MainActor (HIGH)
- **File**: `EditorModel+Capture.swift`
- Five-second disk-capacity checks used synchronous URL resource-value reads from a main-actor task, which could stall recording UI on slow or network-mounted volumes.

### F14. Invalid capture metadata can reach unsafe timing and geometry math (MEDIUM)
- **Files**: `VoiceCleanupAudioProcessing.swift`, `FrameScaler.swift`
- A zero, non-finite, or out-of-range audio sample rate could create an invalid `CMTime` fallback timescale.
- Zero-sized pixel buffers could reach scale-factor division.

### F15. Padded-background cache has no entry cap (MEDIUM)
- **File**: `PaddedBackgroundRenderer.swift`
- Memory-pressure purge bounds lifetime under pressure, but distinct image bookmarks could still accumulate between pressure events.

## Expected Behavior

- Long-lived stored tasks must not retain their UI state owner indefinitely and must be cancelled during teardown.
- Critical stop, landing, replay cleanup, and session cleanup work must keep only the model/session/manager dependencies required to finish, even if the initiating panel disappears.
- Recording disk-capacity reads must not block the main actor.
- Malformed sample rates and pixel dimensions must fail safely without invalid CoreMedia timing or division by zero.
- The padded-background image cache must remain bounded and must participate in coordinated memory-pressure purge.
