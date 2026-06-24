import Foundation
import CoreMedia

// MARK: - Audio bus mixing

/// Baseline volume for a single audio track on the master bus, computed from
/// the project's master gain and the track's per-track input.
public enum AudioBusMixing: Sendable {
    /// Linear baseline: `masterGain × trackGain`.
    public static func baselineVolume(masterGain: Float, trackInput: TrackInput?) -> Float {
        let trackGain = trackInput?.gain ?? 1
        return masterGain * trackGain
    }
}
