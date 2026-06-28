import CoreImage
import CoreVideo
import Metal

/// GPU-accelerated frame scaler using Core Image. Scales and crops captured
/// frames to the writer's fixed canvas dimensions when the source resolution
/// changes mid-session (source switching).
nonisolated final class FrameScaler: @unchecked Sendable {
    private let ciContext: CIContext
    private let targetWidth: Int
    private let targetHeight: Int
    private let pixelFormat: OSType
    /// Reusable pixel buffer pool to avoid per-frame CVPixelBufferCreate overhead.
    private let pool: CVPixelBufferPool?

    /// Lanzcos scale transform filter, cached and reused per instance.
    private static let filterName = "CILanczosScaleTransform"

    init(targetWidth: Int, targetHeight: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.pixelFormat = pixelFormat
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }
        // Create a pixel buffer pool for efficient buffer reuse.
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 2,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0,
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var poolOut: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &poolOut)
        self.pool = poolOut
    }

    /// Scale a pixel buffer to the target dimensions. Returns `nil` if scaling
    /// fails (e.g. incompatible pixel format). The returned buffer is suitable
    /// for appending to the `AVAssetWriter`.
    func scale(_ sourceBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)

        // No scaling needed if dimensions already match.
        guard sourceWidth != targetWidth || sourceHeight != targetHeight else {
            return sourceBuffer
        }

        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)

        // Compute the scale factor. We scale to fill the target, then center-crop.
        let scaleX = Double(targetWidth) / Double(sourceWidth)
        let scaleY = Double(targetHeight) / Double(sourceHeight)
        let scale = max(scaleX, scaleY)

        // Apply scale.
        guard let scaleFilter = CIFilter(name: Self.filterName) else { return nil }
        scaleFilter.setValue(sourceImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let scaledImage = scaleFilter.outputImage else { return nil }

        // Center-crop to exact target dimensions.
        let cropRect = CGRect(
            x: (scaledImage.extent.width - CGFloat(targetWidth)) / 2,
            y: (scaledImage.extent.height - CGFloat(targetHeight)) / 2,
            width: CGFloat(targetWidth),
            height: CGFloat(targetHeight))
        let croppedImage = scaledImage.cropped(to: cropRect)

        // Allocate from the pool when available, fall back to one-shot create.
        var outputBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        } else {
            CVPixelBufferCreate(
                kCFAllocatorDefault, targetWidth, targetHeight, pixelFormat,
                nil, &outputBuffer)
        }
        guard let output = outputBuffer else { return nil }

        ciContext.render(croppedImage, to: output)
        return output
    }
}
