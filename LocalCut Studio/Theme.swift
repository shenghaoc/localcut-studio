import SwiftUI

/// Visual identity tokens for the editor. Kept intentionally small: one brand
/// accent plus a couple of timeline surface tints so panels read as a deliberate
/// dark "studio" rather than the default SwiftUI grey.
extension Color {
    /// LocalCut Studio brand accent — a warm film-gold. Every other NLE reaches
    /// for blue or teal; the gold is the one memorable colour of the chrome and
    /// stays distinct from the red scrub playhead.
    static let lcAccent = Color(red: 0.96, green: 0.67, blue: 0.26)

    /// Lane fill for the timeline body so empty tracks still read as a surface
    /// instead of a void.
    static let lcLane = Color(red: 0.12, green: 0.13, blue: 0.15)

    /// Slightly lifted ruler/gutter surface above the lanes.
    static let lcRail = Color(red: 0.16, green: 0.17, blue: 0.20)
}
