import Foundation
import AVFoundation
import CoreMedia

/// Focused state container for playback and preview functionality.
/// Extracted from EditorModel to improve cohesion and testability.
@Observable
@MainActor
final class PlaybackState {
    /// The shared AVPlayer for preview playback.
    let player = AVPlayer()
    /// Whether the player is currently playing.
    var isPlaying = false
    /// Whether a preview item is loaded.
    var hasPreviewItem = false
    /// Playhead position in seconds.
    var currentTime: Double = 0
    /// Total duration of the current composition in seconds.
    var totalDuration: Double = 0

    /// Timeline view state
    var pixelsPerSecond: Double = 80

    // MARK: - Time observer

    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    init() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main) { [weak self] notification in
            guard notification.object as? AVPlayerItem == self?.player.currentItem else { return }
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Replaces the current preview item.
    func replaceItem(with item: AVPlayerItem?) {
        player.replaceCurrentItem(with: item)
        hasPreviewItem = item != nil
    }

    /// Seeks to the given time with zero tolerance (frame-accurate).
    func seek(to seconds: Double) {
        seek(to: seconds, tolerance: .zero)
    }

    /// Seeks to the given time with caller-supplied tolerance.
    func seek(to seconds: Double, tolerance: CMTime) {
        let clamped = max(0, min(seconds, totalDuration))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }
}
