import Foundation
import LocalCutCore

@MainActor
final class ExportCoordinator {
    /// Exports using the default preset (toolbar/menu shortcut).
    func export(to url: URL, model: EditorModel) async -> EditorCommandOutcome {
        await export(to: url, model: model, preset: BuiltInExportPresets.defaultPreset)
    }

    /// Exports using a specific preset (from the render queue inspector).
    func export(to url: URL, model: EditorModel, preset: ExportPreset) async -> EditorCommandOutcome {
        await export(to: url, model: model) { preparedBookmark in
            let snapshot = ProjectDocument(
                project: model.project,
                queueSessionLocation: model.projectSessionLocation)
            let job = QueueJob(
                preset: preset,
                outputBookmark: preparedBookmark.data,
                outputDisplayName: url.lastPathComponent,
                projectSnapshot: snapshot,
                outputReservationCreated: preparedBookmark.placeholderURL != nil)
            return model.renderQueue.enqueue(job)
        }
    }

    func export(
        to url: URL,
        model: EditorModel,
        enqueue: @MainActor (RenderQueue.PreparedOutputBookmark) -> QueueEnqueueOutcome
    ) async -> EditorCommandOutcome {
        guard let preparedBookmark = RenderQueue.prepareOutputBookmark(for: url) else {
            model.statusMessage = "Could not access \(url.lastPathComponent). Check that the destination is writable."
            return .failed
        }
        switch enqueue(preparedBookmark) {
        case .queued:
            model.statusMessage = "Queued \(url.lastPathComponent). The render will start shortly — check the Renders section in the inspector for progress."
            return .completed
        case .failed(let message):
            preparedBookmark.discardPlaceholder()
            model.statusMessage = message
            return .failed
        }
    }
}
