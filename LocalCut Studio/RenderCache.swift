import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import os

// MARK: - Key

/// Identifies one post-effect-chain frame. Equality on this key implies
/// pixel-equivalence of the cached image at the same render canvas.
///
/// `effectChainHash` is a `Hasher` digest of `[Effect]`, the same approach
/// `CaptionStyle.rasterHash` uses. `time` is normalised to a high-precision
/// (microsecond) timescale before being stored, so equivalent times expressed
/// in different timescales (e.g. preview's frame-rate timescale vs export's
/// source-asset timescale for the same instant) collapse to one key.
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

    init(clipID: UUID, effectChainHash: Int, time: CMTime, renderSize: CGSize) {
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
    }

    var time: CMTime { CMTime(value: timeValue, timescale: timeScale) }
    var renderSize: CGSize { CGSize(width: renderWidth, height: renderHeight) }
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
/// `OSAllocatedUnfairLock`-guarded ordered dictionary, LRU-touched on lookup,
/// evicted from the front on insert past the cap.
final class RenderCache: @unchecked Sendable {

    /// Default in-memory budget in bytes (256 MiB). At 1080p (8 MiB/frame) the
    /// cache holds ~32 frames before LRU starts evicting; at 4K (33 MiB/frame)
    /// ~7. Tunable so the diagnostics panel (P25) can dial it down on
    /// lower-RAM Macs.
    nonisolated static let defaultByteBudget: Int = 256 * 1024 * 1024

    /// Shared singleton used by `EffectCompositor`. The compositor is created
    /// per render pass by AVFoundation, so the cache must outlive any single
    /// compositor instance; matches the existing `sharedCaptionRasterer` shape
    /// and lets preview and export share one warm cache.
    nonisolated static let shared = RenderCache()

    /// Sandbox-allowed on-disk cache directory for future disk-spill use.
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

    /// `order` is least-recent at index 0; back-of-array is most-recently-used.
    /// `totalBytes` tracks the sum of `entries[k].byteCost` so eviction does
    /// not have to re-walk the dictionary on every insert.
    private struct CacheState {
        var entries: [RenderCacheKey: Entry] = [:]
        var order: [RenderCacheKey] = []
        var totalBytes: Int = 0
    }
    private let lock = OSAllocatedUnfairLock(initialState: CacheState())

    nonisolated init(byteBudget: Int = RenderCache.defaultByteBudget) {
        precondition(byteBudget > 0, "byteBudget must be positive")
        self.budget = byteBudget
    }

    nonisolated var byteBudget: Int { budget }

    nonisolated var currentBytes: Int {
        lock.withLock { $0.totalBytes }
    }

    nonisolated var count: Int {
        lock.withLock { $0.entries.count }
    }

    /// LRU lookup. Touches the matched key to the most-recently-used position
    /// so a hot frame stays warm even when the cache is near its budget.
    nonisolated func image(for key: RenderCacheKey) -> CIImage? {
        lock.withLock { state -> CIImage? in
            guard let entry = state.entries[key] else { return nil }
            if let i = state.order.firstIndex(of: key) {
                state.order.remove(at: i)
            }
            state.order.append(key)
            return entry.image
        }
    }

    /// Insert (or replace) the image for `key`, evicting least-recently-used
    /// entries from the front until `totalBytes <= byteBudget`.
    nonisolated func setImage(_ image: CIImage, for key: RenderCacheKey) {
        let bytes = Self.estimatedBytes(for: image, fallback: key)
        let entry = Entry(image: image, byteCost: bytes)
        lock.withLock { state in
            if let existing = state.entries[key] {
                state.totalBytes -= existing.byteCost
                // Keep position in `order`; a re-insert is also a touch.
                if let i = state.order.firstIndex(of: key) {
                    state.order.remove(at: i)
                }
            }
            state.entries[key] = entry
            state.order.append(key)
            state.totalBytes += bytes
            while state.totalBytes > self.budget, let oldest = state.order.first {
                state.order.removeFirst()
                if let removed = state.entries.removeValue(forKey: oldest) {
                    state.totalBytes -= removed.byteCost
                }
            }
        }
    }

    /// Drop every entry whose key matches the given clip. Called by the editor
    /// when a clip's effect chain mutates; correctness does not depend on this
    /// (a changed chain produces a new `effectChainHash` and therefore a new
    /// key) but it releases bytes the LRU would otherwise hold until natural
    /// eviction.
    nonisolated func invalidate(clipID: UUID) {
        lock.withLock { state in
            var dropped: Set<RenderCacheKey> = []
            for key in state.entries.keys where key.clipID == clipID {
                dropped.insert(key)
            }
            for key in dropped {
                if let removed = state.entries.removeValue(forKey: key) {
                    state.totalBytes -= removed.byteCost
                }
            }
            if !dropped.isEmpty {
                state.order.removeAll { dropped.contains($0) }
            }
        }
    }

    /// Drop every entry whose render size differs from `size`. Called after a
    /// project render-size change so stale-canvas frames release their bytes.
    nonisolated func invalidate(notMatchingRenderSize size: CGSize) {
        let w = max(0, Int(size.width.rounded()))
        let h = max(0, Int(size.height.rounded()))
        lock.withLock { state in
            var dropped: Set<RenderCacheKey> = []
            for key in state.entries.keys where key.renderWidth != w || key.renderHeight != h {
                dropped.insert(key)
            }
            for key in dropped {
                if let removed = state.entries.removeValue(forKey: key) {
                    state.totalBytes -= removed.byteCost
                }
            }
            if !dropped.isEmpty {
                state.order.removeAll { dropped.contains($0) }
            }
        }
    }

    /// Empty the cache and reset `totalBytes` to zero.
    nonisolated func purge() {
        lock.withLock { state in
            state.entries.removeAll()
            state.order.removeAll()
            state.totalBytes = 0
        }
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

    /// Raw byte estimate for a `(width, height)` BGRA bitmap. Kept public so
    /// tests can construct expected costs without a CIImage in hand.
    nonisolated static func estimatedBytes(width: Int, height: Int) -> Int {
        max(0, width) * max(0, height) * 4
    }
}
