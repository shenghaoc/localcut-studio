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
        return YouTubeChapterValidator.validate(chapters, projectDuration: project.duration)
    }

    var hasRepairableChapterShortSpans: Bool {
        chapterValidationIssues.contains { issue in
            if case .spanTooShort = issue { return true }
            return false
        }
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

        if result.issues.isEmpty, result.sidecarPath != nil {
            statusMessage = "Chapter sidecar written to \(outputURL.deletingPathExtension().lastPathComponent).chapters.txt"
        } else if result.issues.isEmpty {
            statusMessage = result.embeddedChapterNote ?? "Chapter sidecar write failed."
        } else {
            let issueCount = result.issues.count
            statusMessage = "Chapter sidecar export blocked by \(issueCount) validation issue(s)."
        }
        return result
    }

    @MainActor
    func repairChapterShortSpans(strategy: ChapterShortSpanRepairStrategy) {
        let repaired = YouTubeChapterValidator.repairedMarkers(
            from: project.markers,
            projectDuration: project.duration,
            strategy: strategy)
        guard repaired != project.markers else {
            statusMessage = "No repairable chapter spans found."
            return
        }

        let beforeCount = project.markers.filter { $0.kind == .chapter }.count
        let afterCount = repaired.filter { $0.kind == .chapter }.count
        performUndoable(strategy.displayName) {
            project.markers = repaired
            if let selectedMarkerID,
               !project.markers.contains(where: { $0.id == selectedMarkerID }) {
                self.selectedMarkerID = nil
            }
            let removedCount = beforeCount - afterCount
            statusMessage = "\(strategy.displayName) removed \(removedCount) chapter marker(s)."
        }
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
