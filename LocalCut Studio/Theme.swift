import SwiftUI

// MARK: - View Modifiers

extension View {
    /// Applies `.font(.caption)`, `.monospacedDigit()`, and
    /// `.foregroundStyle(.secondary)` — the standard treatment for
    /// secondary numeric labels (timecodes, counts, bitrates).
    func monospacedCaption() -> some View {
        self
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

// MARK: - Colour Tokens

/// Semantic colour tokens for the editor. Kept intentionally small and sourced
/// from the system so the app follows the user's macOS appearance, accent, and
/// accessibility contrast settings.
extension Color {
    /// The user's macOS control accent. Bespoke timeline and Canvas drawing use
    /// the same semantic colour as native controls and focus rings.
    static let lcAccent = Color.accentColor

    /// Lane fill for the timeline body so empty tracks still read as a recessed
    /// surface instead of a void. Uses the system content-background colour so it
    /// tracks the active appearance rather than pinning a fixed grey.
    static let lcLane = Color(nsColor: .underPageBackgroundColor)

    /// Slightly lifted gutter/ruler surface sitting above the recessed lanes, so
    /// the track headers and time ruler read as a control band. Semantic system
    /// colour so it adapts with the appearance like `lcLane`.
    static let lcRail = Color(nsColor: .windowBackgroundColor)

    /// Caption block fill colour — base indigo for the timeline caption lane;
    /// call sites apply varying opacity. Uses the system indigo so it adapts to
    /// light/dark mode.
    static let lcCaptionFill = Color.indigo

    /// Caption block stroke colour — indigo at 75% opacity for the timeline
    /// caption lane border.
    static let lcCaptionStroke = Color.indigo.opacity(0.75)

    /// Transition glyph fill colour. Neutral so orange remains reserved for
    /// warnings and paused/transient states throughout the app.
    static let lcTransitionFill = Color.secondary

    /// Beat marker colour — yellow at 65% opacity for the timeline ruler.
    static let lcBeatMarker = Color.yellow.opacity(0.65)

    /// Trim handle hover colour — white at 15% opacity for the timeline trim handles.
    static let lcTrimHover = Color.white.opacity(0.15)

    /// Transition glyph icon colour — semantic primary text so it remains
    /// legible in both system appearances.
    static let lcTransitionIcon = Color.primary
}
