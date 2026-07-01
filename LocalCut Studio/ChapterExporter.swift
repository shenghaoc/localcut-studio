import Foundation
import CoreMedia
import AVFoundation
import LocalCutCore

// MARK: - Chapter Exporter

/// Writes YouTube chapter sidecar files and embeds chapter metadata during
/// export. Operates on `.chapter`-kind timeline markers.
nonisolated enum ChapterExporter {

    /// Writes a YouTube chapter `.txt` sidecar alongside the output file.
    ///
    /// - Parameters:
    ///   - markers: Timeline markers (filtered to `.chapter` kind internally).
    ///   - projectDuration: Total project duration.
    ///   - outputURL: The main export output URL. The sidecar is written to the
    ///     same directory with `.chapters.txt` suffix.
    /// - Returns: The export result with sidecar path and validation issues.
    public static func writeYouTubeSidecar(
        markers: [TimelineMarker],
        projectDuration: CMTime,
        outputURL: URL
    ) -> ChapterExportResult {
        let chapters = YouTubeChapterValidator.chapters(from: markers, projectDuration: projectDuration)
        let issues = YouTubeChapterValidator.validate(chapters, projectDuration: projectDuration)
        guard issues.isEmpty else {
            return ChapterExportResult(issues: issues)
        }

        let sidecarURL = outputURL.deletingPathExtension()
            .appendingPathExtension("chapters.txt")
        let content = YouTubeChapterValidator.format(chapters)

        do {
            try content.write(to: sidecarURL, atomically: true, encoding: .utf8)
            return ChapterExportResult(
                sidecarPath: sidecarURL.path,
                embeddedChaptersWritten: false,
                embeddedChapterNote: nil,
                issues: issues)
        } catch {
            var result = ChapterExportResult(issues: issues)
            result.sidecarPath = nil
            result.embeddedChapterNote = "Failed to write sidecar: \(error.localizedDescription)"
            return result
        }
    }

    /// Generates `AVMutableMetadataItem` entries for chapter metadata.
    ///
    /// - Parameters:
    ///   - markers: Timeline markers (filtered to `.chapter` kind internally).
    ///   - projectDuration: Total project duration.
    /// - Returns: Metadata items for embedding, or empty if no chapters.
    public static func chapterMetadataItems(
        from markers: [TimelineMarker],
        projectDuration: CMTime
    ) -> [AVMutableMetadataItem] {
        let chapters = YouTubeChapterValidator.chapters(from: markers, projectDuration: projectDuration)
        guard !chapters.isEmpty,
              YouTubeChapterValidator.validate(chapters, projectDuration: projectDuration).isEmpty else {
            return []
        }

        var items: [AVMutableMetadataItem] = []
        for (index, chapter) in chapters.enumerated() {
            // Chapter title item.
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = chapter.title as NSString
            titleItem.dataType = kCMMetadataBaseDataType_UTF8 as String
            titleItem.locale = Locale.current
            titleItem.time = chapter.time
            let rawDuration = index + 1 < chapters.count
                ? chapters[index + 1].time - chapter.time
                : projectDuration - chapter.time
            // Clamp to non-negative to avoid corrupt metadata when a marker
            // is placed at or past the project end. Also guard against NaN
            // from non-numeric CMTime subtraction (max(0, NaN) returns NaN).
            let clampedSeconds = rawDuration.seconds.isFinite ? max(0, rawDuration.seconds) : 0
            titleItem.duration = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
            items.append(titleItem)
        }
        return items
    }

    public static func chapterTimedMetadataGroups(
        from markers: [TimelineMarker],
        projectDuration: CMTime
    ) -> [AVTimedMetadataGroup] {
        chapterMetadataItems(from: markers, projectDuration: projectDuration).compactMap { item in
            let range = CMTimeRange(start: item.time, duration: item.duration)
            guard range.duration > .zero else { return nil }
            return AVTimedMetadataGroup(items: [item], timeRange: range)
        }
    }

    public static func chapterMetadataFormatDescription() -> CMFormatDescription? {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                AVMetadataIdentifier.commonIdentifierTitle.rawValue,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_UTF8 as String,
        ]
        var formatDescription: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &formatDescription)
        guard status == noErr else { return nil }
        return formatDescription
    }
}
