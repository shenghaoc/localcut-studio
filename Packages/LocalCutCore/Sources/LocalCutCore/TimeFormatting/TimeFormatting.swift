import Foundation

/// Shared seconds → timecode formatting.
public enum TimeFormatting: Sendable {
    public static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        // Round to nearest hundredth to avoid floating-point drift
        // (e.g. 1.29 → 0.28999… → 28 without rounding).
        let hundredths = Int(((seconds - floor(seconds)) * 100).rounded())
        return String(format: "%d:%02d.%02d", minutes, secs, hundredths)
    }
}
