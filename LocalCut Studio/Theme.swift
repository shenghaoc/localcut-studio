import SwiftUI

/// Visual identity tokens for the editor. Kept intentionally small and sourced
/// from the system rather than hard-coded RGB: the brand accent lives in the
/// asset catalog (Display-P3, with room for light/dark + high-contrast variants)
/// and the timeline surface is a semantic system colour that adapts on its own.
extension Color {
    /// LocalCut Studio brand accent — a warm film-gold defined in
    /// `Assets.xcassets` as `AccentColor`. Referenced by name so it resolves
    /// today; once the target's *Global Accent Color Name* build setting points
    /// at `AccentColor`, `Color.accentColor` (and every system focus ring /
    /// selection highlight) inherits the same gold app-wide. Every other NLE
    /// reaches for blue or teal; the gold stays distinct from the red playhead.
    static let lcAccent = Color("AccentColor")

    /// Lane fill for the timeline body so empty tracks still read as a recessed
    /// surface instead of a void. Uses the system content-background colour so it
    /// tracks the active appearance rather than pinning a fixed grey.
    static let lcLane = Color(nsColor: .underPageBackgroundColor)

    /// Slightly lifted gutter/ruler surface sitting above the recessed lanes, so
    /// the track headers and time ruler read as a control band. Semantic system
    /// colour so it adapts with the appearance like `lcLane`.
    static let lcRail = Color(nsColor: .windowBackgroundColor)

    /// Caption block fill colour — indigo at varying opacity for the timeline
    /// caption lane. Uses the system indigo so it adapts to light/dark mode.
    static let lcCaptionFill = Color.indigo

    /// Caption block stroke colour — indigo at 75% opacity for the timeline
    /// caption lane border.
    static let lcCaptionStroke = Color.indigo.opacity(0.75)

    /// Transition glyph fill colour — orange at varying opacity for the timeline
    /// transition overlay.
    static let lcTransitionFill = Color.orange

    /// Beat marker colour — yellow at 65% opacity for the timeline ruler.
    static let lcBeatMarker = Color.yellow.opacity(0.65)

    /// Trim handle hover colour — white at 15% opacity for the timeline trim handles.
    static let lcTrimHover = Color.white.opacity(0.15)

    /// Transition glyph icon colour — white for the timeline transition icon.
    static let lcTransitionIcon = Color.white
}
