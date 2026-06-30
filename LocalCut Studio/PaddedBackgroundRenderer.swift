import Foundation
import AppKit
import CoreImage
import CoreGraphics
import LocalCutCore

/// Renders the padded-background preset as a CIImage for compositing behind
/// the clip in the effect pipeline.
nonisolated enum PaddedBackgroundRenderer {

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
            locations: [0, 1]
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
    private static func drawImage(
        context: CGContext,
        bookmark: Data,
        renderSize: CGSize
    ) -> Bool {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }

        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }

        // Downsample to render size to avoid holding giant images in memory.
        let maxDimension = max(renderSize.width, renderSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return false
        }

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
}
