import Foundation
import CoreMedia
import LocalCutCore

// MARK: - Chapter Export (Phase 44)

extension EditorModel {

    /// Whether the project has chapter markers.
    var hasChapterMarkers: Bool {
        project.markers.contains { $0.kind == .chapter }
    }

    /// Chapter validation issues for the current markers.
    var chapterValidationIssues: [ChapterExportIssue] {
        let chapters = YouTubeChapterValidator.chapters(
            from: project.markers, projectDuration: project.duration)
        return YouTubeChapterValidator.validate(chapters)
    }

    /// Exports a YouTube chapter sidecar `.txt` file.
    ///
    /// - Parameter outputURL: The URL for the main export output. The sidecar
    ///   is written alongside it.
    /// - Returns: The export result with sidecar path and issues.
    @MainActor
    func exportYouTubeChapterSidecar(outputURL: URL) -> ChapterExportResult {
        let result = ChapterExporter.writeYouTubeSidecar(
            markers: project.markers,
            projectDuration: project.duration,
            outputURL: outputURL)

        if result.issues.isEmpty {
            statusMessage = "Chapter sidecar written to \(outputURL.deletingPathExtension().lastPathComponent).chapters.txt"
        } else {
            let issueCount = result.issues.count
            statusMessage = "Chapter sidecar written with \(issueCount) validation issue(s)."
        }
        return result
    }

    /// Sets a marker's kind to `.chapter`.
    @MainActor
    func setMarkerKind(_ markerID: TimelineMarker.ID, kind: MarkerKind) {
        guard let index = project.markers.firstIndex(where: { $0.id == markerID }) else { return }
        performUndoable("Set Marker Kind") {
            project.markers[index].kind = kind
        }
    }

    /// Converts all markers to chapter markers (bulk operation).
    @MainActor
    func convertAllMarkersToChapters() {
        performUndoable("Convert Markers to Chapters") {
            for i in project.markers.indices {
                project.markers[i].kind = .chapter
            }
            statusMessage = "Converted \(project.markers.count) marker(s) to chapters."
        }
    }
}
