import Foundation
import CoreMedia

/// Pure geometry for laying out tracks when transitions overlap neighbouring
/// clips.
///
/// Authored clips stay butt-adjacent and non-overlapping in the timeline data
/// model — this keeps trim & drag invariants intact. A transition is realised by
/// *rippling* every clip at or after its cut earlier by the derived overlap, so
/// the rendered timeline shortens by the total transition duration (matching the
/// classic A/B-roll model). The same ripple is applied across all tracks so that
/// linked video and audio stay in sync.
public enum TransitionLayout: Sendable {

    /// A cut on the timeline that hosts a transition, with its clamped overlap.
    public struct Cut: Hashable, Sendable {
        public let time: CMTime
        public let overlap: CMTime
        public init(time: CMTime, overlap: CMTime) {
            self.time = time
            self.overlap = overlap
        }
    }

    /// One clip placed in rippled ("effective") timeline coordinates.
    public struct Placement: Identifiable, Sendable {
        public let clip: Clip
        public let effectiveStart: CMTime
        public let overlap: CMTime

        public init(clip: Clip, effectiveStart: CMTime, overlap: CMTime) {
            self.clip = clip
            self.effectiveStart = effectiveStart
            self.overlap = overlap
        }

        public var id: Clip.ID { clip.id }
        public var effectiveEnd: CMTime { effectiveStart + clip.duration }

        public var transitionRange: CMTimeRange? {
            guard overlap > .zero, clip.transition != nil else { return nil }
            return CMTimeRange(start: effectiveStart, duration: overlap)
        }
    }

    /// Tolerance (seconds) for treating two clips as adjacent despite rounding.
    public static let adjacencyTolerance = 0.001

    /// The clamped overlap for `clip`'s incoming transition given its authored
    /// predecessor. Zero unless a transition exists *and* the clips are adjacent.
    public static func effectiveOverlap(into clip: Clip, previous: Clip?) -> CMTime {
        guard let transition = clip.transition, let previous else { return .zero }
        let gap = abs((clip.timelineStart - previous.timelineEnd).seconds)
        guard gap < adjacencyTolerance else { return .zero }
        let maxOverlap = CMTimeMinimum(previous.duration, clip.duration)
        let clamped = CMTimeMinimum(transition.duration, maxOverlap)
        return CMTimeMaximum(clamped, .zero)
    }

    /// A sub-range of a clip placed in effective (rippled) time.
    public struct Piece: Identifiable, Sendable {
        public let clipID: Clip.ID
        public let index: Int
        public let sourceRange: CMTimeRange
        public let effectiveStart: CMTime
        public let overlap: CMTime

        public init(clipID: Clip.ID, index: Int, sourceRange: CMTimeRange,
                    effectiveStart: CMTime, overlap: CMTime) {
            self.clipID = clipID
            self.index = index
            self.sourceRange = sourceRange
            self.effectiveStart = effectiveStart
            self.overlap = overlap
        }

        public var id: String { "\(clipID)-\(index)" }
        public var duration: CMTime { sourceRange.duration }
        public var effectiveEnd: CMTime { effectiveStart + sourceRange.duration }
        public var transitionRange: CMTimeRange? {
            overlap > .zero ? CMTimeRange(start: effectiveStart, duration: overlap) : nil
        }
    }

    /// Splits `clip` at every cut strictly inside its authored span and returns
    /// the resulting pieces in effective coordinates.
    public static func pieces(for clip: Clip, overlap: CMTime, cuts: [Cut]) -> [Piece] {
        let start = clip.timelineStart
        let end = clip.timelineEnd

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
    /// chained transitions additionally clamped.
    public static func orderedOverlaps(_ ordered: [Clip]) -> [CMTime] {
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
    public static func cuts(videoTracks: [Track]) -> [Cut] {
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

    /// Total leftward ripple applied to authored time `authored`.
    public static func shift(at authored: CMTime, cuts: [Cut]) -> CMTime {
        var shift = CMTime.zero
        for cut in cuts where cut.time <= authored {
            shift = shift + cut.overlap
        }
        return shift
    }

    /// Authored times that draw at the given effective timeline time.
    public static func authoredTimes(forEffective effective: CMTime, cuts: [Cut]) -> [CMTime] {
        let ordered = cuts.sorted { $0.time < $1.time }
        var results: [CMTime] = []
        var cumulativeShift = CMTime.zero
        var lowerBound = CMTime.zero

        for index in 0...ordered.count {
            let upperBound = index < ordered.count ? ordered[index].time : nil
            let authored = effective + cumulativeShift
            let aboveLower = authored.seconds >= lowerBound.seconds - adjacencyTolerance
            let belowUpper = upperBound.map { authored.seconds <= $0.seconds + adjacencyTolerance } ?? true

            if authored >= .zero, aboveLower, belowUpper,
               !results.contains(where: { abs(($0 - authored).seconds) < adjacencyTolerance }) {
                results.append(authored)
            }

            if index < ordered.count {
                lowerBound = ordered[index].time
                cumulativeShift = cumulativeShift + ordered[index].overlap
            }
        }

        return results.sorted { $0 < $1 }
    }

    /// Placements for one track's clips, rippled by the project-wide cut list.
    public static func placements(for clips: [Clip], cuts: [Cut]) -> [Placement] {
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
