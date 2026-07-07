import Foundation

@MainActor
final class ExportCoordinator {
    /// Exports using the default preset (toolbar/menu shortcut).
    func export(to url: URL, model: EditorModel) async -> EditorCommandOutcome {
        await export(to: url, model: model, preset: BuiltInExportPresets.defaultPreset)
    }

    /// Exports using a specific preset (from the render queue inspector).
    func export(to url: URL, model: EditorModel, preset: ExportPreset) async -> EditorCommandOutcome {
        await export(to: url, model: model) { bookmark in
            let snapshot = ProjectDocument(project: model.project, queueBundleURL: model.documentURL)
            let job = QueueJob(
                preset: preset,
                outputBookmark: bookmark,
                outputDisplayName: url.lastPathComponent,
                projectSnapshot: snapshot)
            return model.renderQueue.enqueue(job)
        }
    }

    func export(
        to url: URL,
        model: EditorModel,
        enqueue: @MainActor (Data) -> QueueEnqueueOutcome
    ) async -> EditorCommandOutcome {
        guard let bookmark = RenderQueue.outputBookmark(for: url) else {
            model.statusMessage = "Could not access \(url.lastPathComponent). Check that the destination is writable."
            return .failed
        }
        switch enqueue(bookmark) {
        case .queued:
            model.statusMessage = "Queued \(url.lastPathComponent). The render will start shortly — check the Renders section in the inspector for progress."
            return .completed
        case .failed(let message):
            model.statusMessage = message
            return .failed
        }
    }
}
