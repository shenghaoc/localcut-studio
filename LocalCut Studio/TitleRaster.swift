import Foundation
import CoreGraphics
import CoreText
import CoreImage
import os

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
    let renderWidth: Int
    let renderHeight: Int

    init(lineID: UUID, styleHash: Int, text: String,
         wordHighlightIndex: Int? = nil, renderSize: CGSize) {
        self.lineID = lineID
        self.styleHash = styleHash
        self.text = text
        self.wordHighlightIndex = wordHighlightIndex
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
}

// MARK: - Rasteriser

/// Renders attributed-string-style title text once per `(lineID, styleHash,
/// text, wordHighlightIndex, renderSize)` request and caches the bitmap behind
/// an LRU. The caller owns the Core Text drawing decisions inside the supplied
/// closure; the rasteriser owns the bitmap, the colour space, and the cache.
final class TitleRasterer: @unchecked Sendable {
    /// Caller-supplied draw closure. Receives a flipped CG context whose origin
    /// is the bottom-left of the render canvas, plus the canvas size. The closure
    /// returns the bounding rect of the pixels it drew, in canvas coordinates.
    typealias DrawClosure = @Sendable (CGContext, CGSize) -> CGRect

    private let cap: Int
    nonisolated private static let sRGB: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }()

    /// `order` is least-recent at index 0; back-of-array is most-recently-used.
    private struct CacheState {
        var entries: [TitleRasterRequest: TitleRaster] = [:]
        var order: [TitleRasterRequest] = []
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
            state.entries.removeAll()
            state.order.removeAll()
        }
    }

    nonisolated var count: Int {
        lock.withLock { $0.entries.count }
    }

    // MARK: - Internals

    nonisolated private func lookup(_ request: TitleRasterRequest) -> TitleRaster? {
        lock.withLock { state -> TitleRaster? in
            guard let cached = state.entries[request] else { return nil }
            // Mark most-recently-used.
            if let i = state.order.firstIndex(of: request) {
                state.order.remove(at: i)
            }
            state.order.append(request)
            return cached
        }
    }

    nonisolated private func insert(_ raster: TitleRaster, for request: TitleRasterRequest) {
        lock.withLock { state in
            if state.entries[request] == nil {
                state.entries[request] = raster
                state.order.append(request)
                while state.order.count > cap, let oldest = state.order.first {
                    state.order.removeFirst()
                    state.entries.removeValue(forKey: oldest)
                }
            }
        }
    }

    /// Allocates a render-canvas-sized BGRA premultiplied bitmap, runs the draw
    /// closure with a y-flipped context (so Core Text top-down output composites
    /// correctly under Core Image's bottom-up coordinate space), and wraps the
    /// resulting bitmap in a `CIImage`.
    nonisolated private func render(request: TitleRasterRequest, draw: DrawClosure) -> TitleRaster {
        let size = request.renderSize
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: Self.sRGB,
            bitmapInfo: bitmapInfo) else {
            os_log(.error, "TitleRasterer: could not allocate %dx%d CGContext", width, height)
            return TitleRaster(image: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size)),
                               boundingBox: .zero)
        }

        // Start transparent and y-flip so a top-down Core Text frame maps onto
        // Core Image's bottom-up image coordinate system.
        context.clear(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let boundingBox = draw(context, size)
        context.restoreGState()

        guard let cgImage = context.makeImage() else {
            return TitleRaster(image: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size)),
                               boundingBox: .zero)
        }
        let ciImage = CIImage(cgImage: cgImage)
        return TitleRaster(image: ciImage, boundingBox: boundingBox)
    }
}
