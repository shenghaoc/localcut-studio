import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import os
import LocalCutCore

// MARK: - Key

/// Identifies one post-effect-chain frame. Equality on this key implies
/// pixel-equivalence of the cached image at the same render canvas.
///
/// `effectChainHash` is a `Hasher` digest of `[Effect]`, the same approach
/// `CaptionStyle.rasterHash` uses. `time` is normalised to a high-precision
/// (microsecond) timescale before being stored, so equivalent times expressed
/// in different timescales (e.g. preview's frame-rate timescale vs export's
/// source-asset timescale for the same instant) collapse to one key. Frame
/// rate is part of the identity because grain advances at project cadence.
/// Working colour space is part of the identity because cached materialised
/// frames are evaluated through a colour-space-specific `CIContext`.
nonisolated struct RenderCacheKey: Hashable, Sendable {
    /// Timescale every key is normalised to (microsecond resolution). High
    /// enough that two adjacent frames at any practical project frame rate
    /// stay distinct; low enough that a `CMTime.convertScale` never overflows
    /// `Int64`.
    nonisolated static let normalisedTimescale: CMTimeScale = 1_000_000

    let clipID: UUID
    let effectChainHash: Int
    let timeValue: Int64
    let timeScale: Int32
    let renderWidth: Int
    let renderHeight: Int
    let frameRateMillis: Int
    let workingColourSpace: WorkingColourSpace

    init(clipID: UUID, effectChainHash: Int, time: CMTime, renderSize: CGSize,
         frameRate: Double = 24, workingColourSpace: WorkingColourSpace = .sRGB) {
        self.clipID = clipID
        self.effectChainHash = effectChainHash
        let normalised: CMTime
        if time.isValid, !time.isIndefinite, time.timescale > 0 {
            normalised = time.convertScale(Self.normalisedTimescale, method: .default)
        } else {
            normalised = CMTime(value: 0, timescale: Self.normalisedTimescale)
        }
        self.timeValue = normalised.value
        self.timeScale = normalised.timescale > 0 ? normalised.timescale : Self.normalisedTimescale
        self.renderWidth = max(0, Int(renderSize.width.rounded()))
        self.renderHeight = max(0, Int(renderSize.height.rounded()))
        self.frameRateMillis = Self.normalisedFrameRateMillis(frameRate)
        self.workingColourSpace = workingColourSpace
    }

    var time: CMTime { CMTime(value: timeValue, timescale: timeScale) }
    var renderSize: CGSize { CGSize(width: renderWidth, height: renderHeight) }

    private nonisolated static func normalisedFrameRateMillis(_ frameRate: Double) -> Int {
        let cadence = frameRate.isFinite ? max(1, frameRate) : 1
        return Int((cadence * 1_000).rounded())
    }
}

// MARK: - Effect chain digest

extension Array where Element == Effect {
    /// Process-stable digest over the chain, in order. Equality of this value
    /// implies the chain renders identical pixels. `Hasher` is process-seeded
    /// so this is not stable across launches — the cache is in-memory only.
    ///
    /// We switch on each case manually instead of `hasher.combine(effect)`
    /// because Swift 6's `-default-isolation=MainActor` makes `Effect`'s
    /// synthesised `Hashable` conformance MainActor-isolated, and the
    /// compositor that calls this property is `nonisolated`. The payload
    /// types (`ColourGrade`, `SkinSmoothEffect`) are themselves declared
    /// `nonisolated`, so combining them directly is safe from any context.
    /// Mirrors `Effect.hash(into:)` byte-for-byte so the two stay in sync.
    nonisolated var renderCacheHash: Int {
        var hasher = Hasher()
        for effect in self {
            switch effect {
            case .colourGrade(let g):
                hasher.combine(0); hasher.combine(g)
            case .lut(bookmark: let d):
                hasher.combine(1); hasher.combine(d)
            case .skinSmooth(let s):
                hasher.combine(2); hasher.combine(s)
            case .grain(let g):
                hasher.combine(3); hasher.combine(g)
            case .halation(let h):
                hasher.combine(4); hasher.combine(h)
            case .vignette(let v):
                hasher.combine(5); hasher.combine(v)
            }
        }
        return hasher.finalize()
    }
}

// MARK: - Cache

/// Memoises post-effect-chain `CIImage` frames behind an LRU bounded by a total
/// estimated byte budget. The `EffectCompositor` consults the shared instance
/// before running the per-clip CIFilter pipeline; speed ramps (Phase 35) and
/// frame interpolation (Phase 37) re-request the same source-frame time several
/// times per output frame, which would otherwise re-execute the chain.
///
/// Same shape as `TitleRasterer` in `TitleRaster.swift`: an
/// `OSAllocatedUnfairLock`-guarded dictionary plus linked list, LRU-touched on
/// lookup, evicted from the head on insert past the cap.
final class RenderCache: Sendable {

    /// Default in-memory budget in bytes (128 MiB). At 1080p (8 MiB/frame) the
    /// cache holds ~16 frames before LRU starts evicting; at 4K (33 MiB/frame)
    /// ~3.
    nonisolated static let defaultByteBudget: Int = 128 * 1024 * 1024

    /// Default disk-spill budget (512 MiB).
    nonisolated static let defaultDiskByteBudget: Int = 512 * 1024 * 1024

    /// Shared singleton used by `EffectCompositor`. The compositor is created
    /// per render pass by AVFoundation, so the cache must outlive any single
    /// compositor instance; matches the existing `sharedCaptionRasterer` shape
    /// and lets preview and export share one warm cache.
    nonisolated static let shared = RenderCache()

    /// Sandbox-allowed on-disk cache directory for the spill tier.
    /// App Sandbox grants the container Caches directly per ROADMAP's
    /// "Apple API spot-checks", so no security-scoped bookmark is needed.
    /// Returning `nil` is reserved for environments where `.cachesDirectory`
    /// cannot be resolved (no test runner hits this path today).
    nonisolated static var cacheDirectoryURL: URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.shenghaoc.LocalCutStudio"
        return caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("RenderCache", isDirectory: true)
    }

    private let budget: Int

    private struct Entry: Sendable {
        let image: CIImage
        let byteCost: Int
    }

    private struct DiskEntry: Sendable {
        let url: URL
        let byteCost: Int
    }

    /// `@unchecked Sendable`: linked-list `previous`/`next` pointers are only
    /// mutated under the parent cache's lock.
    nonisolated private final class MemoryNode: @unchecked Sendable {
        let key: RenderCacheKey
        var previous: MemoryNode?
        var next: MemoryNode?

        init(key: RenderCacheKey) {
            self.key = key
        }
    }

    /// `@unchecked Sendable`: linked-list `previous`/`next` pointers are only
    /// mutated under the parent cache's lock.
    nonisolated private final class DiskNode: @unchecked Sendable {
        let key: RenderCacheKey
        var previous: DiskNode?
        var next: DiskNode?

        init(key: RenderCacheKey) {
            self.key = key
        }
    }

    /// `memoryHead` / `diskHead` are least-recent; tails are most-recent.
    /// `totalBytes` tracks the sum of `entries[k].byteCost` so eviction does
    /// not have to re-walk the dictionary on every insert.
    nonisolated private struct CacheState {
        var entries: [RenderCacheKey: Entry] = [:]
        var memoryNodes: [RenderCacheKey: MemoryNode] = [:]
        var memoryHead: MemoryNode?
        var memoryTail: MemoryNode?
        var totalBytes: Int = 0

        var diskEntries: [RenderCacheKey: DiskEntry] = [:]
        var diskNodes: [RenderCacheKey: DiskNode] = [:]
        var diskHead: DiskNode?
        var diskTail: DiskNode?
        var diskBytes: Int = 0

        mutating func touchMemory(_ key: RenderCacheKey) {
            guard let node = memoryNodes[key], memoryTail !== node else { return }
            unlinkMemory(node)
            appendMemoryNode(node)
        }

        mutating func insertMemory(_ key: RenderCacheKey, entry: Entry) {
            if let existing = entries[key] {
                totalBytes -= existing.byteCost
                removeMemoryNode(for: key)
            }
            entries[key] = entry
            appendMemory(key)
            totalBytes += entry.byteCost
        }

        mutating func removeMemoryEntry(for key: RenderCacheKey) -> Entry? {
            removeMemoryNode(for: key)
            guard let removed = entries.removeValue(forKey: key) else { return nil }
            totalBytes -= removed.byteCost
            return removed
        }

        mutating func popLeastRecentMemory() -> (RenderCacheKey, Entry)? {
            guard let oldest = memoryHead else { return nil }
            let key = oldest.key
            guard let entry = removeMemoryEntry(for: key) else { return nil }
            return (key, entry)
        }

        mutating func touchDisk(_ key: RenderCacheKey) {
            guard let node = diskNodes[key], diskTail !== node else { return }
            unlinkDisk(node)
            appendDiskNode(node)
        }

        mutating func insertDisk(_ key: RenderCacheKey, entry: DiskEntry) -> DiskEntry? {
            let previous = diskEntries[key]
            if let previous {
                diskBytes -= previous.byteCost
                removeDiskNode(for: key)
            }
            diskEntries[key] = entry
            appendDisk(key)
            diskBytes += entry.byteCost
            return previous
        }

        mutating func removeDiskEntry(for key: RenderCacheKey) -> DiskEntry? {
            removeDiskNode(for: key)
            guard let removed = diskEntries.removeValue(forKey: key) else { return nil }
            diskBytes -= removed.byteCost
            return removed
        }

        mutating func popLeastRecentDisk() -> (RenderCacheKey, DiskEntry)? {
            guard let oldest = diskHead else { return nil }
            let key = oldest.key
            guard let entry = removeDiskEntry(for: key) else { return nil }
            return (key, entry)
        }

        private mutating func appendMemory(_ key: RenderCacheKey) {
            let node = MemoryNode(key: key)
            memoryNodes[key] = node
            appendMemoryNode(node)
        }

        private mutating func appendMemoryNode(_ node: MemoryNode) {
            node.previous = memoryTail
            node.next = nil
            memoryTail?.next = node
            memoryTail = node
            if memoryHead == nil { memoryHead = node }
        }

        private mutating func removeMemoryNode(for key: RenderCacheKey) {
            guard let node = memoryNodes.removeValue(forKey: key) else { return }
            unlinkMemory(node)
        }

        private mutating func unlinkMemory(_ node: MemoryNode) {
            if memoryHead === node { memoryHead = node.next }
            if memoryTail === node { memoryTail = node.previous }
            node.previous?.next = node.next
            node.next?.previous = node.previous
            node.previous = nil
            node.next = nil
        }

        private mutating func appendDisk(_ key: RenderCacheKey) {
            let node = DiskNode(key: key)
            diskNodes[key] = node
            appendDiskNode(node)
        }

        private mutating func appendDiskNode(_ node: DiskNode) {
            node.previous = diskTail
            node.next = nil
            diskTail?.next = node
            diskTail = node
            if diskHead == nil { diskHead = node }
        }

        private mutating func removeDiskNode(for key: RenderCacheKey) {
            guard let node = diskNodes.removeValue(forKey: key) else { return }
            unlinkDisk(node)
        }

        private mutating func unlinkDisk(_ node: DiskNode) {
            if diskHead === node { diskHead = node.next }
            if diskTail === node { diskTail = node.previous }
            node.previous?.next = node.next
            node.next?.previous = node.previous
            node.previous = nil
            node.next = nil
        }
    }
    private let lock = OSAllocatedUnfairLock(initialState: CacheState())
    private let diskBudget: Int
    private let cacheDirectory: URL?

    /// Creates a CIContext for disk writes that preserves the source color space.
    /// Wide-gamut content (Display P3, Rec. 2020) is written in its native space
    /// instead of being downconverted to sRGB.
    nonisolated static func diskContext(for colorSpace: WorkingColourSpace) -> CIContext {
        let cgSpace = colorSpace.cgColorSpace
        return CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: cgSpace,
            .outputColorSpace: cgSpace,
        ])
    }

    /// Default sRGB context for fallback.
    nonisolated private static let srgbContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
    ])

    nonisolated init(byteBudget: Int = RenderCache.defaultByteBudget,
                     diskByteBudget: Int = RenderCache.defaultDiskByteBudget,
                     cacheDirectory: URL? = RenderCache.cacheDirectoryURL) {
        precondition(byteBudget > 0, "byteBudget must be positive")
        precondition(diskByteBudget >= 0, "diskByteBudget must be non-negative")
        self.budget = byteBudget
        self.diskBudget = diskByteBudget
        self.cacheDirectory = cacheDirectory
        // Clean up orphaned disk cache files from previous sessions.
        cleanUpOrphanedDiskFiles()
    }

    /// Removes disk cache files that are not tracked in the current cache state.
    /// Called at init to prevent unbounded growth from crashed exports.
    private nonisolated func cleanUpOrphanedDiskFiles() {
        guard let cacheDirectory else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }

        let trackedFiles = lock.withLock { state in
            Set(state.diskEntries.values.map { $0.url })
        }

        for file in files where file.pathExtension == "png" {
            if !trackedFiles.contains(file) {
                try? fm.removeItem(at: file)
            }
        }
    }

    nonisolated var byteBudget: Int { budget }

    nonisolated var currentBytes: Int {
        lock.withLock { $0.totalBytes }
    }

    nonisolated var currentDiskBytes: Int {
        lock.withLock { $0.diskBytes }
    }

    nonisolated var count: Int {
        lock.withLock { $0.entries.count }
    }

    nonisolated var diskCount: Int {
        lock.withLock { $0.diskEntries.count }
    }

    /// LRU lookup. Touches the matched key to the most-recently-used position
    /// so a hot frame stays warm even when the cache is near its budget.
    nonisolated func image(for key: RenderCacheKey) -> CIImage? {
        if let cached = lock.withLock({ state -> CIImage? in
            guard let entry = state.entries[key] else { return nil }
            state.touchMemory(key)
            return entry.image
        }) {
            return cached
        }

        guard let diskURL = lock.withLock({ state -> URL? in
            guard let entry = state.diskEntries[key] else { return nil }
            state.touchDisk(key)
            return entry.url
        }) else {
            return nil
        }

        guard let image = CIImage(contentsOf: diskURL) else {
            removeDiskEntry(for: key)
            return nil
        }
        setImage(image, for: key)
        return image
    }

    /// Insert (or replace) the image for `key`, evicting least-recently-used
    /// entries from the front until `totalBytes <= byteBudget`.
    nonisolated func setImage(_ image: CIImage, for key: RenderCacheKey) {
        let bytes = Self.estimatedBytes(for: image, fallback: key)
        let entry = Entry(image: image, byteCost: bytes)
        let evicted = lock.withLock { state -> [(RenderCacheKey, Entry)] in
            state.insertMemory(key, entry: entry)
            var evicted: [(RenderCacheKey, Entry)] = []
            while state.totalBytes > self.budget,
                  let removed = state.popLeastRecentMemory() {
                evicted.append(removed)
            }
            return evicted
        }
        spillEvictedEntries(evicted)
    }

    private nonisolated func spillEvictedEntries(_ entries: [(RenderCacheKey, Entry)]) {
        guard diskBudget > 0, cacheDirectory != nil else { return }
        for (key, entry) in entries {
            if let diskEntry = writeDiskEntry(entry, for: key) {
                recordDiskEntry(diskEntry, for: key)
            } else {
                // Disk write failed (disk full, permissions error). Re-insert
                // the entry into memory so it's not silently lost. The budget
                // will be exceeded temporarily, but the next eviction cycle
                // will handle it.
                lock.withLock { state in
                    state.insertMemory(key, entry: entry)
                }
            }
        }
    }

    private nonisolated func writeDiskEntry(_ entry: Entry, for key: RenderCacheKey) -> DiskEntry? {
        guard let cacheDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory,
                                                    withIntermediateDirectories: true)
            let url = cacheDirectory
                .appendingPathComponent(Self.diskFilename(for: key))
                .appendingPathExtension("png")
            // Use a context that preserves the source color space for wide-gamut content.
            let context = Self.diskContext(for: key.workingColourSpace)
            let colorSpace = key.workingColourSpace.cgColorSpace
            try context.writePNGRepresentation(
                of: entry.image,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return DiskEntry(url: url, byteCost: max(0, values.fileSize ?? entry.byteCost))
        } catch {
            os_log(.error, "RenderCache: disk spill failed: %{public}@",
                   error.localizedDescription)
            return nil
        }
    }

    private nonisolated func recordDiskEntry(_ entry: DiskEntry, for key: RenderCacheKey) {
        // Collect URLs to delete inside the lock, then delete outside.
        // Between releasing the lock and deleting the files, another thread
        // could read a disk entry that's about to be deleted — this causes a
        // brief cache miss (the image loads as nil) which is acceptable since
        // the entry will be regenerated on the next render pass.
        let toDelete = lock.withLock { state -> [URL] in
            var stale: [URL] = []
            if let previous = state.insertDisk(key, entry: entry),
               previous.url != entry.url {
                stale.append(previous.url)
            }
            while state.diskBytes > self.diskBudget,
                  let (_, removed) = state.popLeastRecentDisk() {
                stale.append(removed.url)
            }
            return stale
        }
        removeDiskFiles(toDelete)
    }

    private nonisolated func removeDiskEntry(for key: RenderCacheKey) {
        let removed = lock.withLock { $0.removeDiskEntry(for: key)?.url }
        if let removed {
            removeDiskFiles([removed])
        }
    }

    private nonisolated func removeDiskFiles(_ urls: [URL]) {
        for url in Set(urls) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func diskFilename(for key: RenderCacheKey) -> String {
        [
            key.clipID.uuidString,
            String(key.effectChainHash),
            String(key.timeValue),
            String(key.timeScale),
            "\(key.renderWidth)x\(key.renderHeight)",
            "\(key.frameRateMillis)fps",
        ].joined(separator: "-")
    }

    private nonisolated func removeEntries(matching shouldDrop: @Sendable (RenderCacheKey) -> Bool) {
        let diskFiles = lock.withLock { state -> [URL] in
            let memoryKeys = state.entries.keys.filter(shouldDrop)
            for key in memoryKeys {
                _ = state.removeMemoryEntry(for: key)
            }
            let diskKeys = state.diskEntries.keys.filter(shouldDrop)
            return diskKeys.compactMap { state.removeDiskEntry(for: $0)?.url }
        }
        removeDiskFiles(diskFiles)
    }

    private nonisolated func removeAllEntries() {
        let diskFiles = lock.withLock { state -> [URL] in
            let urls = state.diskEntries.values.map(\.url)
            // Break retain cycles in both doubly-linked lists before clearing.
            for node in state.memoryNodes.values {
                node.previous = nil
                node.next = nil
            }
            for node in state.diskNodes.values {
                node.previous = nil
                node.next = nil
            }
            state.entries.removeAll()
            state.memoryNodes.removeAll()
            state.memoryHead = nil
            state.memoryTail = nil
            state.totalBytes = 0
            state.diskEntries.removeAll()
            state.diskNodes.removeAll()
            state.diskHead = nil
            state.diskTail = nil
            state.diskBytes = 0
            return urls
        }
        removeDiskFiles(diskFiles)
    }

    /// Drop every entry whose key matches the given clip. Called by the editor
    /// when a clip's effect chain mutates; correctness does not depend on this
    /// (a changed chain produces a new `effectChainHash` and therefore a new
    /// key) but it releases bytes the LRU would otherwise hold until natural
    /// eviction.
    nonisolated func invalidate(clipID: UUID) {
        removeEntries { $0.clipID == clipID }
    }

    /// Drop entries for a clip whose cached source-media time falls inside
    /// `timeRange`. Speed-ramp edits use this narrower path because the cache
    /// key is source-time based even though the UI edit is authored on the
    /// clip's output curve.
    nonisolated func invalidate(clipID: UUID, timeRange: CMTimeRange) {
        guard timeRange.duration > .zero else { return }
        removeEntries { key in
            key.clipID == clipID && CMTimeRangeContainsTime(timeRange, time: key.time)
        }
    }

    /// Drop every entry whose render size differs from `size`. Called after a
    /// project render-size change so stale-canvas frames release their bytes.
    nonisolated func invalidate(notMatchingRenderSize size: CGSize) {
        let w = max(0, Int(size.width.rounded()))
        let h = max(0, Int(size.height.rounded()))
        removeEntries { $0.renderWidth != w || $0.renderHeight != h }
    }

    /// Empty only the in-memory cache and reset `totalBytes` to zero, leaving
    /// disk-spill metadata and files intact. Used during memory pressure, where
    /// deleting cache files adds I/O without freeing RAM.
    nonisolated func purgeMemory() {
        lock.withLock { state in
            // Break retain cycles in the doubly-linked list before clearing.
            for node in state.memoryNodes.values {
                node.previous = nil
                node.next = nil
            }
            state.entries.removeAll()
            state.memoryNodes.removeAll()
            state.memoryHead = nil
            state.memoryTail = nil
            state.totalBytes = 0
        }
    }

    /// Empty the memory and disk caches, deleting all cache files.
    nonisolated func purge() {
        removeAllEntries()
    }

    /// Estimated per-entry bytes used to drive byte-budget eviction. The
    /// stored `CIImage` is materialised at the source frame's extent, which can
    /// be 2-4x the render canvas (a 4K asset rendered onto a 1080p canvas
    /// stores ~33 MiB but the render canvas only describes ~8 MiB). Sizing the
    /// cost off the image's actual extent keeps the byte budget honest;
    /// the key-based fallback covers degenerate-extent edges.
    nonisolated static func estimatedBytes(for image: CIImage, fallback key: RenderCacheKey) -> Int {
        let extent = image.extent
        if extent.isInfinite || extent.isNull || extent.isEmpty {
            return estimatedBytes(width: key.renderWidth, height: key.renderHeight)
        }
        return estimatedBytes(width: Int(extent.width.rounded()),
                              height: Int(extent.height.rounded()))
    }

    /// Raw byte estimate for a `(width, height)` BGRA bitmap. This is an
    /// upper bound — the actual `CIImage` may be backed by a compressed GPU
    /// texture or use a different pixel format. The overestimate is safe for
    /// budget purposes (premature eviction) but may cause the cache to hold
    /// fewer entries than the budget allows. Kept public so tests can construct
    /// expected costs without a CIImage in hand.
    nonisolated static func estimatedBytes(width: Int, height: Int) -> Int {
        max(0, width) * max(0, height) * 4
    }
}
