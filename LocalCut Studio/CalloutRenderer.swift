import Foundation
import CoreImage
import CoreGraphics
import CoreText
import LocalCutCore

// NOTE: No AppKit import — all drawing uses CoreGraphics and CoreText so
// the compositor can call these methods safely from background threads.

/// Renders callout overlays as CIImages for compositing in the effect pipeline.
nonisolated enum CalloutRenderer {

    // MARK: - Constants

    /// System-yellow equivalent in sRGB (no AppKit dependency).
    private static let calloutYellow = CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)
    /// System-red equivalent in sRGB.
    private static let calloutRed = CGColor(red: 1.0, green: 0.23, blue: 0.18, alpha: 1.0)
    /// White.
    private static let calloutWhite = CGColor(gray: 1.0, alpha: 1.0)

    // MARK: - Arrow Callout

    /// Render an arrow callout as a CIImage.
    static func renderArrow(
        style: ArrowCalloutStyle,
        startPoint: CGPoint,
        endPoint: CGPoint,
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

        // Flip Y so screen-space normalised coordinates (0,0 = top-left) map
        // to CIImage/CGContext pixel space (0,0 = bottom-left).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let sx = CGFloat(startPoint.x) * renderSize.width
        let sy = CGFloat(startPoint.y) * renderSize.height
        let ex = CGFloat(endPoint.x) * renderSize.width
        let ey = CGFloat(endPoint.y) * renderSize.height
        let start = CGPoint(x: sx, y: sy)
        let end = CGPoint(x: ex, y: ey)

        // Draw arrow shaft.
        context.setStrokeColor(calloutYellow)
        context.setLineWidth(CGFloat(style.strokeWidth))
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        // Draw arrowhead.
        let angle = atan2(ey - sy, ex - sx)
        let headLength = CGFloat(style.headLength)
        let headAngle = CGFloat(style.headAngle)

        let head1 = CGPoint(
            x: ex - headLength * cos(angle - headAngle),
            y: ey - headLength * sin(angle - headAngle))
        let head2 = CGPoint(
            x: ex - headLength * cos(angle + headAngle),
            y: ey - headLength * sin(angle + headAngle))

        context.setFillColor(calloutYellow)
        context.move(to: end)
        context.addLine(to: head1)
        context.addLine(to: head2)
        context.closePath()
        context.fillPath()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Box Callout

    /// Render a box callout as a CIImage.
    static func renderBox(
        style: BoxCalloutStyle,
        rect: CGRect,
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

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let boxRect = CGRect(
            x: rect.origin.x * renderSize.width,
            y: rect.origin.y * renderSize.height,
            width: rect.size.width * renderSize.width,
            height: rect.size.height * renderSize.height)

        let cornerSize = CGSize(
            width: CGFloat(style.cornerRadius),
            height: CGFloat(style.cornerRadius))
        let path = CGPath(
            roundedRect: boxRect,
            cornerWidth: cornerSize.width,
            cornerHeight: cornerSize.height,
            transform: nil)

        // Fill (if opacity > 0).
        if style.fillOpacity > 0 {
            let fillColor = calloutYellow.copy(alpha: CGFloat(style.fillOpacity)) ?? calloutYellow
            context.setFillColor(fillColor)
            context.addPath(path)
            context.fillPath()
        }

        // Stroke.
        context.setStrokeColor(calloutYellow)
        context.setLineWidth(CGFloat(style.strokeWidth))
        context.addPath(path)
        context.strokePath()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Step Number Callout

    /// Render a step-number callout as a CIImage using Core Text.
    static func renderStepNumber(
        style: StepNumberCalloutStyle,
        number: Int,
        position: CGPoint,
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

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let cx = CGFloat(position.x) * renderSize.width
        let cy = CGFloat(position.y) * renderSize.height
        let diameter = CGFloat(style.diameter)
        let radius = diameter / 2

        // Draw circle background.
        let circleRect = CGRect(
            x: cx - radius,
            y: cy - radius,
            width: diameter,
            height: diameter)
        context.setFillColor(calloutRed)
        context.fillEllipse(in: circleRect)

        // Draw number text using Core Text (thread-safe, no AppKit).
        let textString = "\(number)"
        let fontSize = CGFloat(style.fontSize)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): calloutWhite,
        ]
        let attrString = NSAttributedString(string: textString, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        // Position text centred in the circle. The CGContext has been flipped
        // (translate + scale), so we draw in the flipped coordinate space.
        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(
            x: cx - bounds.width / 2,
            y: -cy - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Spotlight Callout

    /// Render a spotlight callout as a CIImage using radial gradient masking.
    /// Note: `centre` is in normalised screen-space (0,0 = top-left). Core
    /// Image uses bottom-left origin, so Y is flipped.
    static func renderSpotlight(
        style: SpotlightCalloutStyle,
        centre: CGPoint,
        sourceImage: CIImage,
        renderSize: CGSize
    ) -> CIImage? {
        let cx = CGFloat(centre.x) * renderSize.width
        let cy = (1.0 - CGFloat(centre.y)) * renderSize.height
        let radius = CGFloat(style.radius) * max(renderSize.width, renderSize.height)
        let feather = CGFloat(style.feather) * max(renderSize.width, renderSize.height)

        // Create a radial gradient from transparent (centre) to dark (outside).
        let innerRadius = max(0, radius - feather)
        let outerRadius = radius + feather

        guard let gradientFilter = CIFilter(name: "CIRadialGradient") else { return nil }
        gradientFilter.setValue(CIVector(x: cx, y: cy), forKey: kCIInputCenterKey)
        gradientFilter.setValue(innerRadius, forKey: "inputRadius0")
        gradientFilter.setValue(outerRadius, forKey: "inputRadius1")
        gradientFilter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor0")
        gradientFilter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(style.dimOpacity)),
                                forKey: "inputColor1")

        guard let gradientImage = gradientFilter.outputImage else { return nil }
        let croppedGradient = gradientImage.cropped(to: CGRect(origin: .zero, size: renderSize))

        return croppedGradient.composited(over: sourceImage)
    }

    // MARK: - Blur Region Callout

    /// Render a blur-region callout as a CIImage.
    /// Note: `rect` is in normalised screen-space (0,0 = top-left). Core
    /// Image uses bottom-left origin, so Y is flipped.
    static func renderBlurRegion(
        style: BlurRegionCalloutStyle,
        rect: CGRect,
        sourceImage: CIImage,
        renderSize: CGSize
    ) -> CIImage? {
        let blurRect = CGRect(
            x: rect.origin.x * renderSize.width,
            y: (1.0 - rect.origin.y - rect.size.height) * renderSize.height,
            width: rect.size.width * renderSize.width,
            height: rect.size.height * renderSize.height)

        // Crop the source to the blur region, clamp edges to prevent
        // transparent fade, then blur. Without clamping, GaussianBlur
        // extends beyond the crop boundary and fades to transparent black.
        let cropped = sourceImage.cropped(to: blurRect)
            .clampedToExtent()

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(cropped, forKey: kCIInputImageKey)
        blurFilter.setValue(CGFloat(style.blurRadius), forKey: kCIInputRadiusKey)

        guard let blurred = blurFilter.outputImage else { return nil }

        // Create a rounded-rect mask for the blur region.
        let maskImage = createRoundedRectMask(
            rect: blurRect,
            cornerRadius: CGFloat(style.cornerRadius),
            renderSize: renderSize)

        // Composite: where mask is white, use blurred; where black, use original.
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(blurred, forKey: kCIInputImageKey)
        blendFilter.setValue(sourceImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)

        return blendFilter.outputImage
    }

    // MARK: - Helpers

    /// Create a rounded-rect mask image (white inside, black outside).
    /// Shared by callout blur-region rendering and the compositor's padded-
    /// background inset masking.
    static func createRoundedRectMask(
        rect: CGRect,
        cornerRadius: CGFloat,
        renderSize: CGSize
    ) -> CIImage {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage(color: CIColor.white).cropped(to: CGRect(origin: .zero, size: renderSize))
        }

        // Black background.
        context.setFillColor(CGColor.black)
        context.fill(CGRect(origin: .zero, size: renderSize))

        // White rounded rect.
        context.setFillColor(CGColor.white)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil)
        context.addPath(path)
        context.fillPath()

        guard let cgImage = context.makeImage() else {
            return CIImage(color: CIColor.white).cropped(to: CGRect(origin: .zero, size: renderSize))
        }
        return CIImage(cgImage: cgImage)
    }
}
