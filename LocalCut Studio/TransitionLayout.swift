import Foundation
import AVFoundation

/// Pure geometry for laying out tracks when transitions overlap neighbouring
/// clips.
///
/// Authored clips stay butt-adjacent and non-overlapping in the timeline data
/// model — this keeps trim & drag invariants intact. A transition is realised by
/// *rippling* every clip at or after its cut earlier by the derived overlap, so
/// the rendered timeline shortens by the total transition duration (matching the
/// classic A/B-roll model). The same ripple is applied across all tracks so that
/// linked video and audio stay in sync.
///
/// This computation is shared by `CompositionBuilder` (which builds the
/// composition and instructions) and `TimelineView` (which draws clip blocks and
/// transition glyphs) so that preview, export, and the UI agree on positions.
enum TransitionLayout {

    /// A cut on the timeline that hosts a transition, with its clamped overlap.
    struct Cut: Hashable {
        let time: CMTime
        let overlap: CMTime
    }

    /// One clip placed in rippled ("effective") timeline coordinates.
    struct Placement: Identifiable {
        let clip: Clip
        /// Start after rippling for upstream transitions.
        let effectiveStart: CMTime
        /// Derived overlap of this clip's incoming transition with its
        /// predecessor (0 when there is no transition or the predecessor is not
        /// adjacent). Equals the rendered transition length.
        let overlap: CMTime

        var id: Clip.ID { clip.id }
        var effectiveEnd: CMTime { effectiveStart + clip.duration }

        /// The interval over which this clip's incoming transition runs, in
        /// effective coordinates, or `nil` when no transition is active.
        var transitionRange: CMTimeRange? {
            guard overlap > .zero, clip.transition != nil else { return nil }
            return CMTimeRange(start: effectiveStart, duration: overlap)
        }
    }

    /// Tolerance (seconds) for treating two clips as adjacent despite rounding.
    /// Also the smallest piece worth creating when splitting at a cut.
    static let adjacencyTolerance = 0.001

    /// The clamped overlap for `clip`'s incoming transition given its authored
    /// predecessor. Zero unless a transition exists *and* the clips are adjacent.
    /// Clamped to neither neighbour's length (R1.3) and never negative (R4.1).
    static func effectiveOverlap(into clip: Clip, previous: Clip?) -> CMTime {
        guard let transition = clip.transition, let previous else { return .zero }
        let gap = abs((clip.timelineStart - previous.timelineEnd).seconds)
        guard gap < adjacencyTolerance else { return .zero }
        let maxOverlap = CMTimeMinimum(previous.duration, clip.duration)
        let clamped = CMTimeMinimum(transition.duration, maxOverlap)
        return CMTimeMaximum(clamped, .zero)
    }

    /// A sub-range of a clip placed in effective (rippled) time. A clip that
    /// spans a transition cut on another track is split into several pieces so
    /// each side of the cut ripples by the correct amount and stays in sync.
    struct Piece: Identifiable {
        let clipID: Clip.ID
        let index: Int
        /// Range within the source media to read.
        let sourceRange: CMTimeRange
        /// Where this piece begins on the rippled timeline.
        let effectiveStart: CMTime
        /// Incoming-transition overlap — non-zero only on the head piece of a
        /// clip that owns a transition.
        let overlap: CMTime

        var id: String { "\(clipID)-\(index)" }
        var duration: CMTime { sourceRange.duration }
        var effectiveEnd: CMTime { effectiveStart + sourceRange.duration }
        var transitionRange: CMTimeRange? {
            overlap > .zero ? CMTimeRange(start: effectiveStart, duration: overlap) : nil
        }
    }

    /// Splits `clip` at every cut strictly inside its authored span and returns
    /// the resulting pieces in effective coordinates. Pieces that aren't split
    /// reduce to one entry. `overlap` is the clip's own incoming-transition
    /// overlap, carried on the head piece only.
    static func pieces(for clip: Clip, overlap: CMTime, cuts: [Cut]) -> [Piece] {
        let start = clip.timelineStart
        let end = clip.timelineEnd

        // Only split at cuts comfortably inside the span; a cut within tolerance
        // of either boundary would yield a degenerate sub-frame piece.
        var bounds: [CMTime] = [start]
        for cut in cuts where cut.time.seconds > start.seconds + adjacencyTolerance
            && cut.time.seconds < end.seconds - adjacencyTolerance {
            bounds.append(cut.time)
        }
        bounds.append(end)

        var pieces: [Piece] = []
        for index in 0..<(bounds.count - 1) {
            let lower = bounds[index]
            let upper = bounds[index + 1]
            let duration = upper - lower
            guard duration > .zero else { continue }

            let sourceOffset = lower - start
            let sourceRange = CMTimeRange(start: clip.sourceStart + sourceOffset, duration: duration)
            let effectiveStart = lower - shift(at: lower, cuts: cuts)
            pieces.append(Piece(
                clipID: clip.id,
                index: index,
                sourceRange: sourceRange,
                effectiveStart: effectiveStart,
                overlap: index == 0 ? overlap : .zero))
        }
        return pieces
    }

    /// Overlaps for each clip's incoming transition, in timeline order, with
    /// chained transitions additionally clamped so a clip's incoming and outgoing
    /// transition windows never overlap: the predecessor's head is already
    /// consumed by *its* incoming transition, so only its remaining tail is
    /// available here.
    static func orderedOverlaps(_ ordered: [Clip]) -> [CMTime] {
        var result: [CMTime] = []
        result.reserveCapacity(ordered.count)
        var previous: Clip?
        var previousOverlap = CMTime.zero
        for clip in ordered {
            var overlap = effectiveOverlap(into: clip, previous: previous)
            if let previous {
                let availableTail = CMTimeMaximum(previous.duration - previousOverlap, .zero)
                overlap = CMTimeMinimum(overlap, availableTail)
            }
            result.append(overlap)
            previousOverlap = overlap
            previous = clip
        }
        return result
    }

    /// The project-wide set of transition cuts, derived from every video track.
    /// Cuts that coincide within `adjacencyTolerance` (e.g. the same boundary on
    /// stacked tracks, possibly with tiny floating-point drift) are merged by
    /// taking the larger overlap, so a shared cut never ripples a track twice.
    static func cuts(videoTracks: [Track]) -> [Cut] {
        var rawCuts: [(time: Double, overlap: CMTime)] = []
        for track in videoTracks {
            let ordered = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            let overlaps = orderedOverlaps(ordered)
            for (index, clip) in ordered.enumerated() where overlaps[index] > .zero {
                rawCuts.append((clip.timelineStart.seconds, overlaps[index]))
            }
        }

        var merged: [Cut] = []
        for raw in rawCuts.sorted(by: { $0.time < $1.time }) {
            if let last = merged.last, abs(last.time.seconds - raw.time) < adjacencyTolerance {
                merged[merged.count - 1] = Cut(time: last.time,
                                               overlap: CMTimeMaximum(last.overlap, raw.overlap))
            } else {
                merged.append(Cut(time: CMTime(seconds: raw.time, preferredTimescale: 600),
                                  overlap: raw.overlap))
            }
        }
        return merged
    }

    /// Total leftward ripple applied to authored time `authored`: the sum of the
    /// overlaps of every cut at or before it.
    static func shift(at authored: CMTime, cuts: [Cut]) -> CMTime {
        var shift = CMTime.zero
        for cut in cuts where cut.time <= authored {
            shift = shift + cut.overlap
        }
        return shift
    }

    /// Placements for one track's clips, rippled by the project-wide cut list.
    static func placements(for clips: [Clip], cuts: [Cut]) -> [Placement] {
        let ordered = clips.sorted { $0.timelineStart < $1.timelineStart }
        let overlaps = orderedOverlaps(ordered)
        var result: [Placement] = []
        result.reserveCapacity(ordered.count)
        for (index, clip) in ordered.enumerated() {
            let effectiveStart = clip.timelineStart - shift(at: clip.timelineStart, cuts: cuts)
            result.append(Placement(clip: clip, effectiveStart: effectiveStart, overlap: overlaps[index]))
        }
        return result
    }
}
