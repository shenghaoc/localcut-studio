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
