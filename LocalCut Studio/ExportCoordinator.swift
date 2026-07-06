import Foundation

@MainActor
final class ExportCoordinator {
    func export(to url: URL, model: EditorModel) async -> EditorCommandOutcome {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else {
            model.statusMessage = "Could not access \(url.lastPathComponent)."
            return .failed
        }
        model.renderQueue.enqueueWithDefaultPreset(outputURL: url,
                                                   project: model.project,
                                                   bookmark: bookmark,
                                                   projectDocumentURL: model.documentURL)
        model.statusMessage = "Queued \(url.lastPathComponent) with \(BuiltInExportPresets.defaultPreset.name)."
        return .completed
    }
}
