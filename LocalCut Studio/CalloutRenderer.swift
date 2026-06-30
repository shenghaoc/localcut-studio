import Foundation
import AppKit
import CoreImage
import CoreGraphics
import LocalCutCore

/// Renders callout overlays as CIImages for compositing in the effect pipeline.
nonisolated enum CalloutRenderer {

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

        // Flip Y for Core Image coordinate system (origin at bottom-left).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let sx = CGFloat(startPoint.x) * renderSize.width
        let sy = CGFloat(startPoint.y) * renderSize.height
        let ex = CGFloat(endPoint.x) * renderSize.width
        let ey = CGFloat(endPoint.y) * renderSize.height
        let start = CGPoint(x: sx, y: sy)
        let end = CGPoint(x: ex, y: ey)

        // Draw arrow shaft.
        context.setStrokeColor(NSColor.systemYellow.cgColor)
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

        context.setFillColor(NSColor.systemYellow.cgColor)
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
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(CGFloat(style.fillOpacity)).cgColor)
            context.addPath(path)
            context.fillPath()
        }

        // Stroke.
        context.setStrokeColor(NSColor.systemYellow.cgColor)
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
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fillEllipse(in: circleRect)

        // Draw number text.
        let text = "\(number)" as NSString
        let fontSize = CGFloat(style.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let textPoint = CGPoint(
            x: cx - textSize.width / 2,
            y: cy - textSize.height / 2)

        // Core Graphics Y is flipped, so we need to draw text in the flipped context.
        // Use NSString.draw which handles the flipped context correctly.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        text.draw(at: CGPoint(x: textPoint.x, y: CGFloat(height) - textPoint.y - textSize.height),
                  withAttributes: attributes)
        context.restoreGState()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Spotlight Callout

    /// Render a spotlight callout as a CIImage using radial gradient masking.
    static func renderSpotlight(
        style: SpotlightCalloutStyle,
        centre: CGPoint,
        sourceImage: CIImage,
        renderSize: CGSize
    ) -> CIImage? {
        let cx = CGFloat(centre.x) * renderSize.width
        let cy = CGFloat(centre.y) * renderSize.height
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

        // Darken the source image outside the spotlight.
        guard let blendFilter = CIFilter(name: "CIMultiplyBlendMode") else { return nil }
        blendFilter.setValue(sourceImage, forKey: kCIInputImageKey)
        blendFilter.setValue(croppedGradient, forKey: kCIInputBackgroundImageKey)

        // Actually, we want to darken OUTSIDE, so we need a different approach.
        // Create a dark overlay and mask it with the inverse gradient.
        let darkOverlay = CIImage(color: CIColor(red: 0, green: 0, blue: 0,
                                                  alpha: CGFloat(style.dimOpacity)))
            .cropped(to: CGRect(origin: .zero, size: renderSize))

        // The gradient goes from transparent (inside) to dark (outside).
        // Use the gradient as a mask for the dark overlay.
        guard let maskFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        maskFilter.setValue(darkOverlay, forKey: kCIInputImageKey)
        maskFilter.setValue(sourceImage, forKey: kCIInputBackgroundImageKey)
        maskFilter.setValue(croppedGradient, forKey: kCIInputMaskImageKey)

        return maskFilter.outputImage
    }

    // MARK: - Blur Region Callout

    /// Render a blur-region callout as a CIImage.
    static func renderBlurRegion(
        style: BlurRegionCalloutStyle,
        rect: CGRect,
        sourceImage: CIImage,
        renderSize: CGSize
    ) -> CIImage? {
        let blurRect = CGRect(
            x: rect.origin.x * renderSize.width,
            y: rect.origin.y * renderSize.height,
            width: rect.size.width * renderSize.width,
            height: rect.size.height * renderSize.height)

        // Crop the source to the blur region, blur it, then composite back.
        let cropped = sourceImage.cropped(to: blurRect)

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
    private static func createRoundedRectMask(
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
