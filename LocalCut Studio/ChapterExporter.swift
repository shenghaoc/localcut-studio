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
            titleItem.key = AVMetadataKey.commonKeyTitle as NSString
            titleItem.keySpace = .common
            titleItem.value = chapter.title as NSString
            titleItem.locale = Locale.current
            titleItem.time = chapter.time
            titleItem.duration = index + 1 < chapters.count
                ? chapters[index + 1].time - chapter.time
                : projectDuration - chapter.time
            items.append(titleItem)
        }
        return items
    }
}
