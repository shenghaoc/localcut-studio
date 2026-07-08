import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import os
import LocalCutCore

/// Renders the padded-background preset as a CIImage for compositing behind
/// the clip in the effect pipeline.
nonisolated enum PaddedBackgroundRenderer {

    /// Maximum number of cached background images. At 4K (~33 MB each),
    /// 8 entries ≈ 264 MB — reasonable for a background cache.
    private static let maxCacheEntries = 8

    /// Cache for resolved background images, keyed by bookmark data.
    /// Avoids re-resolving security-scoped bookmarks and re-downsampling on
    /// every video-composition request. LRU-evicted when the cache exceeds
    /// `maxCacheEntries`.
    private static let imageCache = OSAllocatedUnfairLock<
        [Data: (image: CGImage, width: Int, height: Int)]
    >(uncheckedState: [:])

    /// Clear the cache (e.g. when the project is closed or the preset changes).
    static func purgeCache() {
        imageCache.withLock { $0.removeAll() }
    }

    /// Render the padded background at the given canvas size.
    ///
    /// - Parameters:
    ///   - preset: The padded background preset configuration.
    ///   - renderSize: The project canvas size.
    /// - Returns: A CIImage of the full canvas with the background rendered,
    ///   or nil if rendering fails.
    static func render(
        preset: PaddedBackgroundPreset,
        renderSize: CGSize
    ) -> CIImage? {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw the background.
        switch preset.source {
        case .gradient:
            drawGradient(context: context, preset: preset, renderSize: renderSize)
        case .image:
            guard let bookmark = preset.imageBookmark else {
                drawGradient(context: context, preset: preset, renderSize: renderSize)
                break
            }
            if !drawImage(context: context, bookmark: bookmark, renderSize: renderSize) {
                // Fallback to gradient if image fails to load.
                drawGradient(context: context, preset: preset, renderSize: renderSize)
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Gradient Background

    private static func drawGradient(
        context: CGContext,
        preset: PaddedBackgroundPreset,
        renderSize: CGSize
    ) {
        let width = renderSize.width
        let height = renderSize.height

        // Convert SIMD4<Float> toCGColor components.
        let startColor = CGColor(
            red: CGFloat(preset.gradientStart.x),
            green: CGFloat(preset.gradientStart.y),
            blue: CGFloat(preset.gradientStart.z),
            alpha: CGFloat(preset.gradientStart.w))
        let endColor = CGColor(
            red: CGFloat(preset.gradientEnd.x),
            green: CGFloat(preset.gradientEnd.y),
            blue: CGFloat(preset.gradientEnd.z),
            alpha: CGFloat(preset.gradientEnd.w))

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [startColor, endColor] as CFArray,
            locations: [0.0, 1.0]
        ) else {
            context.setFillColor(startColor)
            context.fill(CGRect(origin: .zero, size: renderSize))
            return
        }

        // Compute start/end points based on angle.
        let angle = CGFloat(preset.gradientAngle)
        let cx = width / 2
        let cy = height / 2
        let diagonal = sqrt(width * width + height * height) / 2
        let startX = cx - diagonal * cos(angle)
        let startY = cy - diagonal * sin(angle)
        let endX = cx + diagonal * cos(angle)
        let endY = cy + diagonal * sin(angle)

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: startX, y: startY),
            end: CGPoint(x: endX, y: endY),
            options: [])
    }

    // MARK: - Image Background

    /// Draw a background image, downsampled to fit the render size.
    /// Returns true if successful, false if the image couldn't be loaded.
    /// Uses a cache keyed by bookmark data hash to avoid repeated disk I/O.
    private static func drawImage(
        context: CGContext,
        bookmark: Data,
        renderSize: CGSize
    ) -> Bool {
        let maxDimension = Int(max(renderSize.width, renderSize.height))

        // Check cache first.
        let cached = imageCache.withLock { $0[bookmark] }
        let cgImage: CGImage?
        if let cached, cached.width == maxDimension, cached.height == maxDimension {
            cgImage = cached.image
        } else {
            // Resolve and downsample.
            cgImage = Self.loadAndDownsample(bookmark: bookmark, maxDimension: maxDimension)
            if let cgImage {
                imageCache.withLock { cache in
                    cache[bookmark] = (cgImage, maxDimension, maxDimension)
                    // Evict oldest entries if cache exceeds max size.
                    while cache.count > maxCacheEntries {
                        if let oldestKey = cache.keys.first {
                            cache.removeValue(forKey: oldestKey)
                        }
                    }
                }
            }
        }

        guard let image = cgImage else { return false }

        // Draw the image to fill the canvas (aspect fill).
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scaleX = renderSize.width / imageWidth
        let scaleY = renderSize.height / imageHeight
        let scale = max(scaleX, scaleY) // Aspect fill
        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let x = (renderSize.width - scaledWidth) / 2
        let y = (renderSize.height - scaledHeight) / 2

        context.draw(image, in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight))
        return true
    }

    /// Load and downsample a background image from a security-scoped bookmark.
    private static func loadAndDownsample(bookmark: Data, maxDimension: Int) -> CGImage? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
