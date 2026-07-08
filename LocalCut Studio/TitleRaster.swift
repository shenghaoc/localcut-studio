import Foundation
import CoreGraphics
import CoreText
import CoreImage
import os
import LocalCutCore

// MARK: - Request + result

/// Identifies one cached title bitmap. Caption style and text are folded into the
/// key explicitly so an edit invalidates the bitmap without scanning the cache;
/// render size is part of the key because layout and pixel grid both depend on it.
nonisolated struct TitleRasterRequest: Hashable {
    let lineID: UUID
    let styleHash: Int
    let text: String
    /// Word index when rendering the karaoke-highlight pass; `nil` for idle frames.
    let wordHighlightIndex: Int?
    /// Digest of the line's `words` array (text + range), so a re-aligned ASR
    /// pass or a hand-edited word range invalidates highlight rasters even when
    /// the line id and word index stay the same. `0` when the line has no words.
    let wordsDigest: Int
    let renderWidth: Int
    let renderHeight: Int

    init(lineID: UUID, styleHash: Int, text: String,
         wordHighlightIndex: Int? = nil, wordsDigest: Int = 0,
         renderSize: CGSize) {
        self.lineID = lineID
        self.styleHash = styleHash
        self.text = text
        self.wordHighlightIndex = wordHighlightIndex
        self.wordsDigest = wordsDigest
        self.renderWidth = Int(renderSize.width.rounded())
        self.renderHeight = Int(renderSize.height.rounded())
    }

    var renderSize: CGSize {
        CGSize(width: renderWidth, height: renderHeight)
    }
}

/// A cached title raster, ready to composite into a frame.
struct TitleRaster {
    /// Straight-alpha CIImage at render-canvas coordinates (origin at bottom-left,
    /// matching Core Image's convention).
    let image: CIImage
    /// Bounding rect of the drawn pixels in render-canvas coordinates. Zero when
    /// the draw closure produced nothing.
    let boundingBox: CGRect
    /// Bounds of the glyph/text pixels, excluding any wider background pill.
    /// Defaults to `boundingBox` for non-caption callers.
    let textBox: CGRect

    nonisolated init(image: CIImage, boundingBox: CGRect, textBox: CGRect? = nil) {
        self.image = image
        self.boundingBox = boundingBox
        self.textBox = textBox ?? boundingBox
    }
}

nonisolated struct TitleRasterBounds: Sendable, Equatable {
    let boundingBox: CGRect
    let textBox: CGRect

    init(boundingBox: CGRect, textBox: CGRect? = nil) {
        self.boundingBox = boundingBox
        self.textBox = textBox ?? boundingBox
    }
}

// MARK: - Rasteriser

/// Renders attributed-string-style title text once per `(lineID, styleHash,
/// text, wordHighlightIndex, renderSize)` request and caches the bitmap behind
/// an LRU. The caller owns the Core Text drawing decisions inside the supplied
/// closure; the rasteriser owns the bitmap, the colour space, and the cache.
final class TitleRasterer: Sendable {
    /// Caller-supplied draw closure. Receives a flipped CG context whose origin
    /// is the bottom-left of the render canvas, plus the canvas size. The closure
    /// returns the bounding rect of the pixels it drew, in canvas coordinates.
    typealias DrawClosure = @Sendable (CGContext, CGSize) -> CGRect
    typealias BoundsDrawClosure = @Sendable (CGContext, CGSize) -> TitleRasterBounds

    private let cap: Int
    nonisolated private static let sRGB: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }()

    /// `@unchecked Sendable`: linked-list `previous`/`next` pointers are only
    /// mutated under the parent cache's lock.
    nonisolated private final class CacheNode: @unchecked Sendable {
        let key: TitleRasterRequest
        var previous: CacheNode?
        var next: CacheNode?

        init(key: TitleRasterRequest) {
            self.key = key
        }
    }

    /// `head` is least-recent; `tail` is most-recently-used.
    nonisolated private struct CacheState {
        var entries: [TitleRasterRequest: TitleRaster] = [:]
        var nodes: [TitleRasterRequest: CacheNode] = [:]
        var head: CacheNode?
        var tail: CacheNode?

        mutating func touch(_ request: TitleRasterRequest) {
            guard let node = nodes[request], tail !== node else { return }
            unlink(node)
            appendNode(node)
        }

        mutating func insert(_ raster: TitleRaster, for request: TitleRasterRequest) {
            if entries[request] != nil {
                entries[request] = raster
                touch(request)
                return
            }
            entries[request] = raster
            let node = CacheNode(key: request)
            nodes[request] = node
            appendNode(node)
        }

        mutating func popLeastRecent() {
            guard let oldest = head else { return }
            let key = oldest.key
            unlink(oldest)
            nodes.removeValue(forKey: key)
            entries.removeValue(forKey: key)
        }

        mutating func removeAll() {
            entries.removeAll()
            nodes.removeAll()
            head = nil
            tail = nil
        }

        private mutating func appendNode(_ node: CacheNode) {
            node.previous = tail
            node.next = nil
            tail?.next = node
            tail = node
            if head == nil { head = node }
        }

        private mutating func unlink(_ node: CacheNode) {
            if head === node { head = node.next }
            if tail === node { tail = node.previous }
            node.previous?.next = node.next
            node.next?.previous = node.previous
            node.previous = nil
            node.next = nil
        }
    }
    private let lock = OSAllocatedUnfairLock(initialState: CacheState())

    nonisolated init(capacity: Int = 128) {
        precondition(capacity > 0, "capacity must be positive")
        self.cap = capacity
    }

    /// Returns the cached raster for `request`, drawing once on miss using `draw`.
    /// The closure is invoked at most once per (request, cache-miss) — it must be
    /// pure with respect to its inputs.
    nonisolated func raster(for request: TitleRasterRequest, draw: DrawClosure) -> TitleRaster {
        rasterWithBounds(for: request) { context, size in
            TitleRasterBounds(boundingBox: draw(context, size))
        }
    }

    /// Variant for callers that need text bounds separate from the full drawn
    /// bounds, for example captions with a background pill and typewriter text.
    nonisolated func rasterWithBounds(for request: TitleRasterRequest,
                                      draw: BoundsDrawClosure) -> TitleRaster {
        if let cached = lookup(request) { return cached }
        let raster = render(request: request, draw: draw)
        insert(raster, for: request)
        return raster
    }

    /// Drops every cached entry. Called when render size changes globally or when
    /// the caption track is reset; per-line / per-style invalidation is handled
    /// implicitly by the cache key.
    nonisolated func purge() {
        lock.withLock { state in
            state.removeAll()
        }
    }

    nonisolated var count: Int {
        lock.withLock { $0.entries.count }
    }

    // MARK: - Internals

    nonisolated private func lookup(_ request: TitleRasterRequest) -> TitleRaster? {
        lock.withLock { state -> TitleRaster? in
            guard let cached = state.entries[request] else { return nil }
            state.touch(request)
            return cached
        }
    }

    nonisolated private func insert(_ raster: TitleRaster, for request: TitleRasterRequest) {
        lock.withLock { state in
            state.insert(raster, for: request)
            while state.entries.count > cap {
                state.popLeastRecent()
            }
        }
    }

    /// Allocates a render-canvas-sized BGRA premultiplied bitmap, runs the draw
    /// closure with a y-flipped context (so Core Text top-down output composites
    /// correctly under Core Image's bottom-up coordinate space), then **crops
    /// the resulting `CGImage` to the draw closure's bounding box** before
    /// wrapping it as a `CIImage`. Full-canvas BGRA rasters at 1080p/4K weigh
    /// ~8/33 MiB each; caching 128 of them would blow up to ~1 GiB / ~4 GiB.
    /// Cropping shrinks each cached entry to roughly the text area while leaving
    /// the canvas position intact via a translation on the resulting CIImage.
    nonisolated private func render(request: TitleRasterRequest, draw: BoundsDrawClosure) -> TitleRaster {
        let size = request.renderSize
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let canvasRect = CGRect(origin: .zero, size: size)
        let fallback = CIImage(color: .clear).cropped(to: canvasRect)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: Self.sRGB,
            bitmapInfo: bitmapInfo) else {
            os_log(.error, "TitleRasterer: could not allocate %dx%d CGContext", width, height)
            return TitleRaster(image: fallback, boundingBox: .zero)
        }

        // Start transparent and y-flip so a top-down Core Text frame maps onto
        // Core Image's bottom-up image coordinate system.
        context.clear(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let bounds = draw(context, size)
        context.restoreGState()

        guard let fullImage = context.makeImage() else {
            return TitleRaster(image: fallback, boundingBox: .zero)
        }

        // Degenerate draw → return a clear, canvas-extent CIImage.
        guard bounds.boundingBox.width > 0, bounds.boundingBox.height > 0 else {
            return TitleRaster(image: fallback, boundingBox: .zero)
        }

        // Convert the CIImage-coord (y-up) bounding box into a CGImage-coord
        // (y-down) crop rect, clamped to the canvas so a partly-off-canvas box
        // still yields a valid CGImage.
        let clampedBox = bounds.boundingBox.intersection(canvasRect)
        guard !clampedBox.isEmpty else {
            return TitleRaster(image: fallback, boundingBox: .zero)
        }
        let clampedTextBox = bounds.textBox.intersection(canvasRect)
        let textBox = clampedTextBox.isEmpty ? clampedBox : clampedTextBox
        let cropRect = CGRect(
            x: clampedBox.minX,
            y: CGFloat(height) - clampedBox.maxY,
            width: clampedBox.width,
            height: clampedBox.height)
        guard let cropped = fullImage.cropping(to: cropRect) else {
            // Cropping can fail for degenerate rects; surface the uncropped
            // image rather than dropping the frame entirely.
            return TitleRaster(image: CIImage(cgImage: fullImage),
                               boundingBox: bounds.boundingBox,
                               textBox: textBox)
        }

        // The cropped CIImage has extent (0, 0, w, h); translate so its
        // extent sits where the text actually is on the canvas, leaving the
        // compositor's animation math (centre = boundingBox.mid) unchanged.
        let ciImage = CIImage(cgImage: cropped)
            .transformed(by: CGAffineTransform(translationX: clampedBox.minX,
                                               y: clampedBox.minY))
        return TitleRaster(image: ciImage, boundingBox: bounds.boundingBox, textBox: textBox)
    }
}
