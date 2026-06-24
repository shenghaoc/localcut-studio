import Foundation
import CoreMedia

// MARK: - Track

/// An ordered lane of clips of a single kind.
@Observable
public final class Track: Identifiable, @unchecked Sendable {
    /// `let` so identity stays stable for the runtime lifetime of the track.
    public let id: UUID
    public var name: String
    public let kind: TrackKind
    public var clips: [Clip] = []
    public var isMuted = false

    public init(id: UUID = UUID(), name: String, kind: TrackKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// The first free time at the tail of the track, used for ripple-append.
    public var endTime: CMTime {
        clips.reduce(.zero) { CMTimeMaximum($0, $1.timelineEnd) }
    }
}

// MARK: - Caption Track

/// An ordered lane of caption lines.
@Observable
public final class CaptionTrack: Identifiable, @unchecked Sendable {
    public let id: UUID
    public var name: String
    public var isMuted = false
    public private(set) var lines: [CaptionLine]
    public var defaultStyle: CaptionStyle = .identity

    public init(id: UUID = UUID(), name: String, lines: [CaptionLine] = []) {
        self.id = id
        self.name = name
        self.lines = lines.sorted { $0.range.start < $1.range.start }
    }

    public func addLine(_ line: CaptionLine) {
        if let i = lines.firstIndex(where: { $0.range.start > line.range.start }) {
            lines.insert(line, at: i)
        } else {
            lines.append(line)
        }
    }

    public func removeLine(id: CaptionLine.ID) {
        lines.removeAll { $0.id == id }
    }

    public func updateLine(_ updated: CaptionLine) {
        guard let i = lines.firstIndex(where: { $0.id == updated.id }) else { return }
        lines[i] = updated
        lines.sort { $0.range.start < $1.range.start }
    }

    public func replaceLines(_ newLines: [CaptionLine]) {
        lines = newLines.sorted { $0.range.start < $1.range.start }
    }

    /// Latest end time across every line (and any nested word).
    public var endTime: CMTime {
        lines.reduce(.zero) { CMTimeMaximum($0, $1.endTime) }
    }
}
