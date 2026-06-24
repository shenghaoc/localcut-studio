import Foundation
import CoreMedia

// MARK: - Render planning

/// The minimal description of a clip visible during one instruction interval,
/// used to decide how to composite it.
public struct VisibleSegment: Sendable {
    public let compTrackID: Int32
    public let start: Double
    public let transitionStart: Double?
    public let transitionEnd: Double?
    public let transitionType: TransitionType?
    public let transitionWipeAngle: Double?

    public init(compTrackID: Int32, start: Double,
                transitionStart: Double?, transitionEnd: Double?,
                transitionType: TransitionType?, transitionWipeAngle: Double?) {
        self.compTrackID = compTrackID
        self.start = start
        self.transitionStart = transitionStart
        self.transitionEnd = transitionEnd
        self.transitionType = transitionType
        self.transitionWipeAngle = transitionWipeAngle
    }
}

/// A planned composite step, by composition-track id, bottom-to-top.
public enum PlannedUnit: Equatable, Sendable {
    case layer(Int32)
    case transition(outgoing: Int32, incoming: Int32,
                    type: TransitionType, wipeAngle: Double)
}

/// Decides, for one project track, how to composite the clips visible at
/// `midpoint`. When transitions overlap, the *topmost* active transition wins.
public func planUnits(visible: [VisibleSegment], midpoint: Double) -> [PlannedUnit] {
    func transitionActive(_ seg: VisibleSegment) -> Bool {
        guard let start = seg.transitionStart, let end = seg.transitionEnd else { return false }
        return start <= midpoint && midpoint < end
    }

    if let incoming = visible.last(where: transitionActive),
       let type = incoming.transitionType,
       let outgoing = visible.filter({ $0.start < incoming.start }).max(by: { $0.start < $1.start }) {
        var result: [PlannedUnit] = []
        for seg in visible where seg.compTrackID != incoming.compTrackID && seg.compTrackID != outgoing.compTrackID {
            result.append(.layer(seg.compTrackID))
        }
        result.append(.transition(outgoing: outgoing.compTrackID,
                                  incoming: incoming.compTrackID,
                                  type: type,
                                  wipeAngle: incoming.transitionWipeAngle ?? Transition.defaultWipeAngle))
        return result
    }

    return visible.map { .layer($0.compTrackID) }
}

/// Linearly interpolates `fullFrom` / `fullTo` over `fullRange` and returns
/// the endpoint volumes that correspond to `subRange`.
public func subRampVolumes(fullRange: CMTimeRange,
                           fullFrom: Float,
                           fullTo: Float,
                           subRange: CMTimeRange) -> (Float, Float) {
    let fullDur = fullRange.duration.seconds
    guard fullDur > 0 else { return (fullFrom, fullTo) }
    let t0 = (subRange.start - fullRange.start).seconds / fullDur
    let t1 = (subRange.end - fullRange.start).seconds / fullDur
    let from = fullFrom + (fullTo - fullFrom) * Float(t0)
    let to = fullFrom + (fullTo - fullFrom) * Float(t1)
    return (from, to)
}

/// Lines from each unmuted caption track active at `midpoint`. Accepts value-
/// type tuples rather than `@MainActor` `CaptionTrack` classes so the pure
/// planning logic can run off the main actor.
public func activeCaptionItems(in tracks: [(defaultStyle: CaptionStyle, lines: [CaptionLine], isMuted: Bool)],
                                midpoint: Double) -> [(lineID: UUID, text: String,
                                                       words: [WordTiming]?,
                                                       style: CaptionStyle,
                                                       range: CMTimeRange)] {
    var items: [(lineID: UUID, text: String, words: [WordTiming]?,
                 style: CaptionStyle, range: CMTimeRange)] = []
    for track in tracks where !track.isMuted {
        for line in track.lines {
            let start = line.range.start.seconds
            let end = line.range.end.seconds
            guard start <= midpoint, midpoint < end else { continue }
            items.append((lineID: line.id, text: line.text, words: line.words,
                          style: line.style ?? track.defaultStyle, range: line.range))
        }
    }
    return items
}

/// Aspect-fit a source frame into the render canvas, centered.
public func fitTransform(naturalSize: CGSize,
                          preferredTransform: CGAffineTransform,
                          into renderSize: CGSize) -> CGAffineTransform {
    let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
    guard orientedSize.width > 0, orientedSize.height > 0 else { return preferredTransform }

    var transform = preferredTransform.concatenating(
        CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))

    let scale = min(renderSize.width / orientedSize.width,
                    renderSize.height / orientedSize.height)
    transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

    let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
    let tx = (renderSize.width - scaledSize.width) / 2
    let ty = (renderSize.height - scaledSize.height) / 2
    transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))

    return transform
}
