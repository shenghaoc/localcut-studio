import SwiftUI

/// Visual identity tokens for the editor. Kept intentionally small and sourced
/// from the system rather than hard-coded RGB: the brand accent lives in the
/// asset catalog (Display-P3, with room for light/dark + high-contrast variants)
/// and the timeline surface is a semantic system colour that adapts on its own.
extension Color {
    /// LocalCut Studio brand accent — a warm film-gold defined in
    /// `Assets.xcassets` (`BrandAccent`). Every other NLE reaches for blue or
    /// teal; the gold is the one memorable colour of the chrome and stays
    /// distinct from the red scrub playhead.
    static let lcAccent = Color("BrandAccent")

    /// Lane fill for the timeline body so empty tracks still read as a recessed
    /// surface instead of a void. Uses the system content-background colour so it
    /// tracks the active appearance rather than pinning a fixed grey.
    static let lcLane = Color(nsColor: .underPageBackgroundColor)
}
