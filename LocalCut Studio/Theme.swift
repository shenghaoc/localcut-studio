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
}
