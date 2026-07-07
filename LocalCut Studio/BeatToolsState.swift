import Foundation
import AVFoundation
import LocalCutCore

/// Focused state container for beat analysis and beat-aligned editing.
/// Extracted from EditorModel to improve cohesion and testability.
@Observable
@MainActor
final class BeatToolsState {
    /// Whether beat markers are shown on the timeline ruler.
    var showBeatMarkers = false
    /// Whether clip editing snaps to beat boundaries.
    var snapToBeats = false
    /// Global draw/snap offset in seconds, clamped by the inspector to ±200 ms.
    /// Changing it must drop the projected-beat memo so markers, snap targets,
    /// and cut/align reflect the new offset on the next read.
    var beatOffsetSeconds: Double = 0 {
        didSet { projectedBeatTimesRevision &+= 1 }
    }
    /// Maximum distance for Align to Beat in seconds.
    var beatAlignWindowSeconds: Double = 0.15
    /// Per-source beat analyses. Mutating this set (analysis completes, caches
    /// load, document reset) invalidates the projected-beat memo.
    var beatAnalyses: [MediaItem.ID: BeatAnalysis] = [:] {
        didSet { projectedBeatTimesRevision &+= 1 }
    }

    // MARK: - Projected beat cache

    /// Monotonic revision counter for the projected-beat memo. Bumped on every
    /// mutation that changes the projected timeline (offset, analysis set, clip
    /// geometry). The memo is valid when `projectedBeatTimesRevision` matches
    /// `lastProjectedBeatTimesRevision`.
    @ObservationIgnored var projectedBeatTimesRevision: Int = 0
    @ObservationIgnored var lastProjectedBeatTimesRevision: Int = -1
    @ObservationIgnored var cachedProjectedBeatTimes: [CMTime] = []

    /// Invalidates the projected-beat memo so the next read recomputes.
    func invalidateCache() {
        projectedBeatTimesRevision &+= 1
    }

    /// Per-source cache keys for beat analysis persistence.
    @ObservationIgnored var beatAnalysisKeys: [MediaItem.ID: String] = [:]

    /// In-flight beat analysis task.
    @ObservationIgnored var beatAnalysisTask: Task<Void, Never>?

    /// Whether the selected source can have beats analysed.
    func canAnalyzeBeats(for media: MediaItem?) -> Bool {
        media?.hasAudio == true
    }

    /// Whether the selected clip can be cut at beats.
    func canCutAtBeats(clipID: Clip.ID?, mediaID: MediaItem.ID?) -> Bool {
        guard let mediaID else { return false }
        return beatAnalyses[mediaID] != nil
    }

    /// Whether the selected clip can be aligned to a beat.
    func canAlignToBeat(hasBeats: Bool) -> Bool {
        hasBeats
    }
}
