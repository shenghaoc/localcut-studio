import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import LocalCutCore

// MARK: - Keystroke Overlay Renderer

/// Renders keystroke overlay events as `CIImage` frames. Thread-safe — uses
/// only Core Graphics and Core Text (no AppKit).
nonisolated enum KeystrokeOverlayRenderer {

    /// The visual state of a single keystroke at a given time.
    struct KeystrokeFrame {
        let displayText: String
        let displayMode: KeystrokeDisplayMode
        let opacity: Float
        let position: CGPoint
    }

    /// Evaluates which keystroke events are visible at the given time and
    /// returns their visual frames.
    static func evaluate(
        events: [KeystrokeOverlayEvent],
        style: KeystrokeOverlayStyle,
        currentTime: CMTime,
        renderSize: CGSize
    ) -> [KeystrokeFrame] {
        let currentSeconds = currentTime.seconds
        let fadeIn = Double(style.fadeInDuration)
        let fadeOut = Double(style.fadeOutDuration)
        let hold = Double(style.holdDuration)

        let baseX = CGFloat(style.normalizedX) * renderSize.width
        let baseY = (1 - CGFloat(style.normalizedY)) * renderSize.height

        var frames: [KeystrokeFrame] = []
        var yOffset: CGFloat = 0

        // Show recent events stacked vertically (newest at bottom).
        let recentEvents = events.filter { event in
            let eventTime = event.time.seconds
            let endTime = eventTime + fadeIn + hold + fadeOut
            return currentSeconds >= eventTime && currentSeconds <= endTime
        }

        for event in recentEvents.reversed() {
            let eventTime = event.time.seconds
            let elapsed = currentSeconds - eventTime

            let opacity: Float
            if elapsed < fadeIn {
                opacity = Float(elapsed / fadeIn)
            } else if elapsed < fadeIn + hold {
                opacity = 1.0
            } else if fadeOut > 0 {
                let fadeElapsed = elapsed - fadeIn - hold
                opacity = Float(max(0, 1 - fadeElapsed / fadeOut))
            } else {
                opacity = 0
            }

            guard opacity > 0 else { continue }

            let position = CGPoint(x: baseX, y: baseY + yOffset)
            frames.append(KeystrokeFrame(
                displayText: event.displayText,
                displayMode: event.displayMode,
                opacity: opacity,
                position: position))

            yOffset += CGFloat(style.fontSize) + CGFloat(style.pillPaddingY) * 2 + 8
        }

        return frames
    }

    /// Renders the keystroke overlay as a `CIImage` composited over the source.
    static func render(
        events: [KeystrokeOverlayEvent],
        style: KeystrokeOverlayStyle,
        currentTime: CMTime,
        renderSize: CGSize,
        overlayOpacity: Float
    ) -> CIImage? {
        let frames = evaluate(
            events: events, style: style,
            currentTime: currentTime, renderSize: renderSize)
        guard !frames.isEmpty else { return nil }

        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(origin: .zero, size: renderSize))

        for frame in frames {
            drawKeystroke(frame: frame, style: style, context: context, renderSize: renderSize)
        }

        guard let cgImage = context.makeImage() else { return nil }
        var image = CIImage(cgImage: cgImage)
        if overlayOpacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(overlayOpacity))
            ])
        }
        return image
    }

    // MARK: - Drawing

    private static func drawKeystroke(
        frame: KeystrokeFrame,
        style: KeystrokeOverlayStyle,
        context: CGContext,
        renderSize: CGSize
    ) {
        let fontSize = CGFloat(style.fontSize)
        let fontName = style.fontName as CFString
        let ctFont = CTFontCreateWithName(fontName, fontSize, nil)

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: CGFloat(frame.opacity))
        ]
        let attributedString = NSAttributedString(
            string: frame.displayText,
            attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let textWidth = bounds.width
        let textHeight = bounds.height

        let padX = CGFloat(style.pillPaddingX)
        let padY = CGFloat(style.pillPaddingY)
        let pillWidth = textWidth + padX * 2
        let pillHeight = textHeight + padY * 2
        let cornerRadius = CGFloat(style.pillCornerRadius)

        let pillX = frame.position.x - pillWidth / 2
        let pillY = frame.position.y - pillHeight / 2
        let pillRect = CGRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)

        // Draw pill background.
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: cornerRadius,
                              cornerHeight: cornerRadius, transform: nil)
        context.saveGState()
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12,
                                     alpha: CGFloat(frame.opacity) * 0.92))
        context.addPath(pillPath)
        context.fillPath()
        context.restoreGState()

        // Draw text.
        context.saveGState()
        let textX = frame.position.x - textWidth / 2
        let textY = frame.position.y - textHeight / 2 - bounds.origin.y
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
