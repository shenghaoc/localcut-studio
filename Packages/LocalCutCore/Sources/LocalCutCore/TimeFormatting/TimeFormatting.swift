import Foundation

/// Shared seconds → timecode formatting.
public enum TimeFormatting: Sendable {
    private static let maxSaneSeconds: Double = 100 * 60 * 60

    public static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= maxSaneSeconds else { return "0:00.00" }
        let totalHundredths = Int((seconds * 100).rounded())
        let minutes = totalHundredths / 6000
        let secs = (totalHundredths % 6000) / 100
        let hundredths = totalHundredths % 100
        return String(format: "%d:%02d.%02d", minutes, secs, hundredths)
    }
}
