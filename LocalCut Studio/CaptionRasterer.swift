import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import CoreImage
import AppKit

/// Renders a `CaptionLine` for a given `CaptionStyle` and render canvas into a
/// `CIImage`. Idle and word-highlight rasters are cached by `TitleRasterer`.
final class CaptionRasterer: Sendable {
    private let rasterer: TitleRasterer

    nonisolated init(rasterer: TitleRasterer = TitleRasterer()) {
        self.rasterer = rasterer
    }

    /// Renders the idle (no active word) frame for a line. Returns nil when the
    /// canvas is degenerate.
    nonisolated func idleRaster(line: CaptionLine, style: CaptionStyle, renderSize: CGSize) -> TitleRaster? {
        guard renderSize.width > 0, renderSize.height > 0 else { return nil }
        let request = TitleRasterRequest(
            lineID: line.id,
            styleHash: style.rasterHash,
            text: line.text,
            wordHighlightIndex: nil,
            renderSize: renderSize)
        return rasterer.raster(for: request) { context, size in
            CaptionDrawing.draw(text: line.text, style: style,
                                size: size, activeWordIndex: nil, words: line.words,
                                into: context)
        }
    }

    /// Renders the word-highlight frame for a line at index `wordIndex` (0-based).
    /// The cache key includes a digest of `line.words` so a re-aligned ASR pass
    /// (or any other change to the word ranges / text) invalidates the cached
    /// raster — the wordIndex alone doesn't capture which substring is now
    /// covered when the words array shifts.
    nonisolated func highlightRaster(line: CaptionLine, style: CaptionStyle, renderSize: CGSize,
                                     wordIndex: Int) -> TitleRaster? {
        guard renderSize.width > 0, renderSize.height > 0 else { return nil }
        let request = TitleRasterRequest(
            lineID: line.id,
            styleHash: style.rasterHash,
            text: line.text,
            wordHighlightIndex: wordIndex,
            wordsDigest: Self.wordsDigest(line.words),
            renderSize: renderSize)
        return rasterer.raster(for: request) { context, size in
            CaptionDrawing.draw(text: line.text, style: style,
                                size: size, activeWordIndex: wordIndex, words: line.words,
                                into: context)
        }
    }

    /// Stable hash of a `WordTiming` array — order-sensitive, text + range
    /// included — used as part of the highlight cache key.
    nonisolated private static func wordsDigest(_ words: [WordTiming]?) -> Int {
        guard let words, !words.isEmpty else { return 0 }
        var hasher = Hasher()
        for w in words {
            hasher.combine(w.word)
            hasher.combine(w.range.start.value)
            hasher.combine(w.range.start.timescale)
            hasher.combine(w.range.duration.value)
            hasher.combine(w.range.duration.timescale)
        }
        return hasher.finalize()
    }

    nonisolated func purge() { rasterer.purge() }

    /// Diagnostic — number of cached rasters. Exposed for the colour-management
    /// invalidation test (R6.1).
    nonisolated var count: Int { rasterer.count }
}

// MARK: - Drawing

/// Pure drawing closures, separated so the rasterer cache stays straightforward.
nonisolated enum CaptionDrawing {

    /// Lays out `text` into a single line using Core Text and draws shadow → pill
    /// → stroke → fill, applying the active-word recolour if `activeWordIndex`
    /// is non-nil. Returns the bounding rect in canvas (bottom-left origin)
    /// coordinates. The closure's context has already been y-flipped.
    @discardableResult
    static func draw(text: String, style: CaptionStyle, size: CGSize,
                     activeWordIndex: Int?, words: [WordTiming]?,
                     into context: CGContext) -> CGRect {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .zero }

        let attributed = attributedString(for: trimmed, style: style,
                                          activeWordIndex: activeWordIndex,
                                          words: words)
        // Wrap inside a horizontal box that respects pill padding.
        let maxWidth = max(64, size.width - CGFloat(style.pill.paddingX) * 2 - 32)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frameSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)

        let textWidth = frameSize.width
        let textHeight = frameSize.height
        guard textWidth > 0, textHeight > 0 else { return .zero }

        let originX = (size.width - textWidth) / 2
        let originY = textOriginY(canvasHeight: size.height,
                                  textHeight: textHeight, style: style)
        let textRect = CGRect(x: originX, y: originY,
                              width: textWidth, height: textHeight)

        // Background pill.
        let pillAlpha = style.pill.colour.alpha
        if pillAlpha > 0 {
            let inset = CGSize(width: CGFloat(-style.pill.paddingX),
                               height: CGFloat(-style.pill.paddingY))
            let pillRect = textRect.insetBy(dx: inset.width, dy: inset.height)
            let path = CGPath(roundedRect: pillRect,
                              cornerWidth: CGFloat(style.pill.cornerRadius),
                              cornerHeight: CGFloat(style.pill.cornerRadius),
                              transform: nil)
            context.saveGState()
            context.addPath(path)
            context.setFillColor(style.pill.colour.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        // Glow drawn before shadow + text by stamping the alpha mask with a soft
        // colour underneath. Cheap approximation that survives without a Metal
        // pass; Phase 38 can swap in a richer kernel.
        if style.glow.radius > 0 && style.glow.colour.alpha > 0 {
            context.saveGState()
            context.setShadow(offset: .zero,
                              blur: CGFloat(style.glow.radius),
                              color: style.glow.colour.cgColor)
            let glowFrame = CTFramesetterCreateFrame(framesetter,
                CFRange(location: 0, length: 0),
                CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(glowFrame, context)
            context.restoreGState()
        }

        // Shadow under the text proper.
        if style.shadow.blur > 0 || style.shadow.offsetX != 0 || style.shadow.offsetY != 0 {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: CGFloat(style.shadow.offsetX),
                               height: CGFloat(style.shadow.offsetY)),
                blur: CGFloat(style.shadow.blur),
                color: style.shadow.colour.cgColor)
            let shadowFrame = CTFramesetterCreateFrame(framesetter,
                CFRange(location: 0, length: 0),
                CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(shadowFrame, context)
            context.restoreGState()
        }

        // Actual text: Core Text reads stroke/fill attributes from the attributed
        // string, so one draw covers both layers in the right order per glyph run.
        let frame = CTFramesetterCreateFrame(framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, context)

        let inset = CGSize(width: CGFloat(-style.pill.paddingX),
                           height: CGFloat(-style.pill.paddingY))
        return textRect.insetBy(dx: inset.width, dy: inset.height)
    }

    /// Y origin of the text rect inside the canvas, given the line's anchor.
    private static func textOriginY(canvasHeight: CGFloat, textHeight: CGFloat,
                                    style: CaptionStyle) -> CGFloat {
        switch style.anchor {
        case .top:
            // Top anchor with an inset from the top edge.
            return canvasHeight - CGFloat(style.verticalInset) - textHeight
        case .middle:
            return (canvasHeight - textHeight) / 2
        case .bottom:
            return CGFloat(style.verticalInset)
        }
    }

    /// Builds the `NSAttributedString` for one line. Active-word recolour swaps
    /// the fill colour for the glyph range covering that word.
    private static func attributedString(for text: String, style: CaptionStyle,
                                         activeWordIndex: Int?,
                                         words: [WordTiming]?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        let font = makeFont(name: style.fontName, size: CGFloat(style.fontSize))

        var base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: style.fill.cgColor) ?? .white,
            .kern: CGFloat(style.letterSpacing),
        ]
        // A negative stroke width tells Core Text to draw stroke *and* fill; a
        // positive width would draw stroke only. The fill colour stays the one
        // set above.
        if style.stroke.width > 0 {
            base[.strokeWidth] = NSNumber(value: -Double(style.stroke.width))
            base[.strokeColor] = NSColor(cgColor: style.stroke.colour.cgColor) ?? .black
        }
        // Centred paragraph alignment so wrap rows centre across the canvas.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        base[.paragraphStyle] = paragraph
        result.addAttributes(base, range: full)

        if let activeWordIndex,
           let words,
           let range = wordRange(for: words, index: activeWordIndex, in: text) {
            result.addAttribute(.foregroundColor,
                                value: NSColor(cgColor: style.wordHighlightFill.cgColor) ?? .yellow,
                                range: range)
        }
        return result
    }

    /// Maps `WordTiming.word` instances onto `NSRange`s in `text`. Naive linear
    /// scan: starts at 0 and walks forward word-by-word so duplicates resolve to
    /// the next occurrence after the previous match.
    private static func wordRange(for words: [WordTiming], index: Int,
                                  in text: String) -> NSRange? {
        guard index >= 0, index < words.count else { return nil }
        let ns = text as NSString
        var cursor = 0
        for i in 0...index {
            let word = words[i].word
            guard !word.isEmpty else { return nil }
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            let found = ns.range(of: word, options: [], range: searchRange)
            guard found.location != NSNotFound else { return nil }
            if i == index { return found }
            cursor = found.location + found.length
        }
        return nil
    }

    /// Resolves the requested PostScript-named font. `CTFontCreateWithName`
    /// silently falls back to a system font for unknown names — we accept that
    /// rather than probing Font Manager and risking exclusion of installed
    /// user fonts. Phase 30 presets reference system-shipped fonts to make
    /// the silent fallback rare in practice.
    private static func makeFont(name: String, size: CGFloat) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }
}

// MARK: - Animation

/// The per-frame visual state of an animating line.
struct CaptionAnimationFrame: Equatable {
    var translation: CGSize = .zero
    var scale: CGFloat = 1
    var opacity: Float = 1
    /// 0...1 horizontal mask progress used by `typewriter`. 1 ⇒ fully visible.
    var typewriterProgress: Float = 1
}

/// Pure animation evaluator. Inputs are local times in seconds; outputs are
/// deterministic — same inputs ⇒ same frame.
nonisolated enum CaptionAnimation {

    /// Evaluates the visual state for a line at `currentTime` (project clock).
    /// `lineStart` and `lineEnd` are the line's range edges. `style` supplies
    /// the enter / exit kinds and durations.
    ///
    /// If the configured `enterDuration + exitDuration` would extend past the
    /// line's own duration the two values are scaled DOWN proportionally so
    /// they fit. The style object itself is left untouched (it is reused across
    /// caption lines of varying lengths and `clamp()` cannot know the
    /// per-line duration), and the inspector keeps showing the user's authored
    /// values. The scaling only applies at evaluation time, per line, so a
    /// 2 s caption with `enterDuration = 2 s` + `exitDuration = 1 s` plays a
    /// 1.33 s enter followed by a 0.67 s exit instead of overlapping into a
    /// simultaneous pop-in + fade-out.
    static func evaluate(currentTime: CMTime,
                         lineStart: CMTime,
                         lineEnd: CMTime,
                         style: CaptionStyle) -> CaptionAnimationFrame {
        let now = currentTime.seconds
        let start = lineStart.seconds
        let end = lineEnd.seconds
        guard end > start else { return CaptionAnimationFrame() }

        let lineDuration = end - start
        var enter = style.enterDuration
        var exit = style.exitDuration
        let totalAnimation = enter + exit
        if totalAnimation > lineDuration && totalAnimation > 0 {
            let scale = lineDuration / totalAnimation
            enter *= scale
            exit *= scale
        }

        var frame = CaptionAnimationFrame()

        // Enter window.
        if enter > 0 {
            let t = clamp(Float((now - start) / enter))
            apply(enter: style.enterAnimation, slide: style.slideDirection, t: t, into: &frame)
        }

        // Exit window.
        if exit > 0 {
            let exitStart = end - exit
            if now >= exitStart {
                let t = clamp(Float((now - exitStart) / exit))
                apply(exit: style.exitAnimation, slide: style.slideDirection, t: t, into: &frame)
            }
        }

        return frame
    }

    private static func apply(enter: CaptionEnterAnimation,
                              slide direction: SlideDirection,
                              t: Float,
                              into frame: inout CaptionAnimationFrame) {
        switch enter {
        case .none:
            return
        case .pop:
            let eased = easeOut(t)
            frame.scale = CGFloat(Float.lerp(0.6, 1, t: eased))
            frame.opacity = Float.lerp(0, 1, t: eased)
        case .bounce:
            let s = bouncedScale(t)
            frame.scale = CGFloat(s)
            frame.opacity = Float.lerp(0, 1, t: easeOut(t))
        case .slide:
            let eased = easeOut(t)
            let dist: CGFloat = 200
            // Core Image uses y-up coordinates (origin at bottom-left), so a
            // positive `translation.height` shifts the caption *above* its rest
            // position. `fromBottom` therefore starts with a NEGATIVE y offset
            // (below rest) and slides up to it; `fromTop` is the mirror.
            switch direction {
            case .fromBottom: frame.translation = CGSize(width: 0, height: -dist * (1 - CGFloat(eased)))
            case .fromTop:    frame.translation = CGSize(width: 0, height:  dist * (1 - CGFloat(eased)))
            case .fromLeft:   frame.translation = CGSize(width: -dist * (1 - CGFloat(eased)), height: 0)
            case .fromRight:  frame.translation = CGSize(width:  dist * (1 - CGFloat(eased)), height: 0)
            }
            frame.opacity = Float.lerp(0, 1, t: eased)
        case .typewriter:
            // Reveal text as a horizontal mask 0→1 across enterDuration.
            frame.typewriterProgress = t
        }
    }

    private static func apply(exit: CaptionExitAnimation,
                              slide direction: SlideDirection,
                              t: Float,
                              into frame: inout CaptionAnimationFrame) {
        switch exit {
        case .none:
            return
        case .pop:
            let eased = easeIn(t)
            frame.scale = min(frame.scale, CGFloat(Float.lerp(1, 0.6, t: eased)))
            frame.opacity = min(frame.opacity, Float.lerp(1, 0, t: eased))
        case .slide:
            let eased = easeIn(t)
            let dist: CGFloat = 200
            switch direction {
            case .fromBottom: frame.translation.height -= dist * CGFloat(eased)
            case .fromTop:    frame.translation.height += dist * CGFloat(eased)
            case .fromLeft:   frame.translation.width  -= dist * CGFloat(eased)
            case .fromRight:  frame.translation.width  += dist * CGFloat(eased)
            }
            frame.opacity = min(frame.opacity, Float.lerp(1, 0, t: eased))
        case .fade:
            frame.opacity = min(frame.opacity, Float.lerp(1, 0, t: t))
        }
    }

    // MARK: - Easing

    private static func clamp(_ t: Float) -> Float { min(1, max(0, t)) }
    private static func easeOut(_ t: Float) -> Float { 1 - pow(1 - clamp(t), 3) }
    private static func easeIn(_ t: Float) -> Float { pow(clamp(t), 3) }

    /// Damped overshoot curve for the `bounce` enter animation. Returns ≈1 at
    /// `t=1` and overshoots slightly along the way.
    static func bouncedScale(_ t: Float) -> Float {
        let clamped = clamp(t)
        if clamped >= 1 { return 1 }
        let damped = 1 - exp(-6 * clamped)
        let oscillation = sin(clamped * .pi * 3) * (1 - clamped)
        return damped + 0.18 * oscillation
    }
}
