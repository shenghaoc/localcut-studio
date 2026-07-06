import Foundation

@MainActor
final class ExportCoordinator {
    func export(to url: URL, model: EditorModel) async -> EditorCommandOutcome {
        await export(to: url, model: model) { bookmark in
            model.renderQueue.enqueueWithDefaultPreset(outputURL: url,
                                                       project: model.project,
                                                       bookmark: bookmark,
                                                       projectDocumentURL: model.documentURL)
        }
    }

    func export(
        to url: URL,
        model: EditorModel,
        enqueue: @MainActor (Data) -> QueueEnqueueOutcome
    ) async -> EditorCommandOutcome {
        guard let bookmark = RenderQueue.outputBookmark(for: url) else {
            model.statusMessage = "Could not access \(url.lastPathComponent)."
            return .failed
        }
        switch enqueue(bookmark) {
        case .queued:
            model.statusMessage = "Queued \(url.lastPathComponent) with \(BuiltInExportPresets.defaultPreset.name)."
            return .completed
        case .failed(let message):
            model.statusMessage = message
            return .failed
        }
    }
}
