import Foundation
import CoreMedia

// MARK: - YouTube Chapter Line

/// A single chapter entry formatted for YouTube's chapter sidecar format.
public struct YouTubeChapterLine: Hashable, Sendable {
    /// The chapter start time.
    public var time: CMTime
    /// The chapter title (must be non-empty after trimming).
    public var title: String

    public init(time: CMTime, title: String) {
        self.time = time
        self.title = title
    }

}

extension YouTubeChapterLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case time, title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        title = try c.decode(String.self, forKey: .title)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(title, forKey: .title)
    }
}

extension YouTubeChapterLine {
    /// Formats this line as `MM:SS Title` or `HH:MM:SS Title`.
    public var formatted: String {
        let totalSeconds = max(0, time.seconds)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        let timestamp: String
        if hours > 0 {
            timestamp = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            timestamp = String(format: "%02d:%02d", minutes, seconds)
        }
        return "\(timestamp) \(title)"
    }
}

// MARK: - Chapter Export Validation Issue

/// A validation issue found when checking chapter markers against YouTube's
/// format rules.
public enum ChapterExportIssue: Hashable, Sendable {
    /// The first chapter does not start at 00:00.
    case firstChapterNotAtZero
    /// Fewer than 3 chapters provided.
    case insufficientChapters(count: Int)
    /// A chapter has an empty title.
    case emptyTitle(index: Int)
    /// Chapter times are not monotonically increasing.
    case nonMonotonicTime(index: Int)
    /// A chapter span is shorter than 10 seconds.
    case spanTooShort(index: Int, duration: Double)

    public var localizedDescription: String {
        switch self {
        case .firstChapterNotAtZero:
            "First chapter must start at 00:00."
        case .insufficientChapters(let count):
            "YouTube requires at least 3 chapters; found \(count)."
        case .emptyTitle(let index):
            "Chapter \(index + 1) has an empty title."
        case .nonMonotonicTime(let index):
            "Chapter \(index + 1) time is not after the previous chapter."
        case .spanTooShort(let index, let duration):
            String(format: "Chapter %d span is %.1fs; minimum is 10s.", index + 1, duration)
        }
    }
}

// MARK: - Chapter Short-Span Repair

/// Automatic repair strategy for chapter spans that fail YouTube's 10-second
/// minimum duration rule.
public enum ChapterShortSpanRepairStrategy: String, Hashable, Codable, Sendable, CaseIterable {
    /// Remove the following chapter boundary where possible so the short span
    /// extends into the next chapter.
    case merge
    /// Remove the chapter that owns the short span where possible. The first
    /// chapter is preserved so the 00:00 rule remains intact.
    case drop

    public var displayName: String {
        switch self {
        case .merge: "Merge Short Spans"
        case .drop: "Drop Short Chapters"
        }
    }
}

// MARK: - Chapter Export Result

/// The result of exporting chapter metadata.
public struct ChapterExportResult: Hashable, Sendable {
    /// Path to the written YouTube `.txt` sidecar, if written.
    public var sidecarPath: String?
    /// Whether embedded chapter metadata was written into the output file.
    public var embeddedChaptersWritten: Bool
    /// A note about embedded chapter support (e.g. "container does not support
    /// embedded chapters; sidecar written instead").
    public var embeddedChapterNote: String?
    /// Validation issues found, if any.
    public var issues: [ChapterExportIssue]

    public init(sidecarPath: String? = nil,
                embeddedChaptersWritten: Bool = false,
                embeddedChapterNote: String? = nil,
                issues: [ChapterExportIssue] = []) {
        self.sidecarPath = sidecarPath
        self.embeddedChaptersWritten = embeddedChaptersWritten
        self.embeddedChapterNote = embeddedChapterNote
        self.issues = issues
    }
}

// MARK: - YouTube Chapter Validator

/// Validates and formats timeline markers for YouTube chapter sidecar export.
public enum YouTubeChapterValidator: Sendable {

    /// Validates chapter markers against YouTube's format rules.
    ///
    /// Rules:
    /// 1. First chapter must start at 00:00.
    /// 2. At least 3 chapters required.
    /// 3. Chapter times must be monotonically increasing.
    /// 4. Each chapter span must be at least 10 seconds.
    /// 5. Titles must be non-empty after trimming.
    ///
    /// - Parameter chapters: The chapter lines to validate, sorted by time.
    /// - Returns: An array of validation issues (empty if valid).
    public static func validate(_ chapters: [YouTubeChapterLine],
                                projectDuration: CMTime? = nil) -> [ChapterExportIssue] {
        var issues: [ChapterExportIssue] = []

        guard !chapters.isEmpty else {
            issues.append(.insufficientChapters(count: 0))
            return issues
        }

        if chapters.count < 3 {
            issues.append(.insufficientChapters(count: chapters.count))
        }

        // First chapter must start at 00:00.
        let firstTime = chapters[0].time.seconds
        if firstTime > 0.5 {
            issues.append(.firstChapterNotAtZero)
        }

        // Check each chapter.
        for (index, chapter) in chapters.enumerated() {
            // Non-empty title.
            if chapter.title.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.emptyTitle(index: index))
            }

            // Monotonic time.
            if index > 0 {
                let prevTime = chapters[index - 1].time.seconds
                if chapter.time.seconds <= prevTime {
                    issues.append(.nonMonotonicTime(index: index))
                }
            }

            // Span ≥ 10s. For the final chapter this requires a known project
            // duration; older callers without that context keep the previous
            // next-chapter-only behavior.
            let spanEnd: Double?
            if index + 1 < chapters.count {
                spanEnd = chapters[index + 1].time.seconds
            } else if let projectDuration, projectDuration.seconds.isFinite {
                spanEnd = projectDuration.seconds
            } else {
                spanEnd = nil
            }
            guard let spanEnd else { continue }
            let span = spanEnd - chapter.time.seconds
            if span < 10 {
                issues.append(.spanTooShort(index: index, duration: span))
            }
        }

        return issues
    }

    /// Formats validated chapters as YouTube `.txt` sidecar content.
    ///
    /// - Parameter chapters: Chapter lines sorted by time.
    /// - Returns: The formatted text, one chapter per line.
    public static func format(_ chapters: [YouTubeChapterLine]) -> String {
        chapters.map(\.formatted).joined(separator: "\n")
    }

    /// Converts chapter-kind timeline markers to `YouTubeChapterLine` entries.
    ///
    /// - Parameters:
    ///   - markers: All timeline markers (will be filtered to `.chapter` kind).
    ///   - projectDuration: The total project duration for the last chapter span.
    /// - Returns: Chapter lines sorted by time.
    public static func chapters(from markers: [TimelineMarker],
                                projectDuration: CMTime) -> [YouTubeChapterLine] {
        let chapterMarkers = markers
            .filter { $0.kind == .chapter }
            .sorted { $0.time.seconds < $1.time.seconds }
        return chapterMarkers.map { marker in
            YouTubeChapterLine(time: marker.time, title: marker.name)
        }
    }

    /// Returns a marker list with short chapter spans resolved according to the
    /// chosen strategy. Non-chapter markers are preserved unchanged.
    public static func repairedMarkers(from markers: [TimelineMarker],
                                       projectDuration: CMTime,
                                       strategy: ChapterShortSpanRepairStrategy) -> [TimelineMarker] {
        var repaired = markers
        var attempts = 0

        while attempts < markers.count {
            let chapterMarkers = repaired
                .filter { $0.kind == .chapter }
                .sorted { $0.time.seconds < $1.time.seconds }
            let chapters = chapterMarkers.map { YouTubeChapterLine(time: $0.time, title: $0.name) }
            let issues = validate(chapters, projectDuration: projectDuration)
            guard let shortSpan = issues.compactMap({ issue -> (index: Int, duration: Double)? in
                if case .spanTooShort(let index, let duration) = issue {
                    return (index, duration)
                }
                return nil
            }).first else {
                break
            }

            let removeIndex: Int?
            switch strategy {
            case .merge:
                if shortSpan.index + 1 < chapterMarkers.count {
                    removeIndex = shortSpan.index + 1
                } else if shortSpan.index > 0 {
                    removeIndex = shortSpan.index
                } else {
                    removeIndex = nil
                }
            case .drop:
                if shortSpan.index > 0 {
                    removeIndex = shortSpan.index
                } else if shortSpan.index + 1 < chapterMarkers.count {
                    removeIndex = shortSpan.index + 1
                } else {
                    removeIndex = shortSpan.index
                }
            }

            guard let removeIndex,
                  chapterMarkers.indices.contains(removeIndex) else { break }
            let removedID = chapterMarkers[removeIndex].id
            repaired.removeAll { $0.id == removedID }
            attempts += 1
        }

        return repaired
    }
}
