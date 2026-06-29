import AppIntents
import Foundation

/// Main-actor bridge from system-discovered App Intents into the live editor.
/// App Intents may be invoked while the app is foregrounded by Shortcuts, Siri,
/// or Spotlight; the actions stay thin and reuse the same model commands as the
/// menu bar so document prompts, panels, and validation remain consistent.
@MainActor
enum LocalCutAppIntentRouter {
    enum Action: String, CaseIterable, Sendable {
        case newProject
        case importMedia
        case exportProject
        case showDiagnostics
    }

    enum RouterError: LocalizedError, Equatable {
        case modelUnavailable
        case emptyTimeline
        case actionCancelled

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                "The editor is not ready. Please ensure LocalCut Studio is open."
            case .emptyTimeline:
                "Add media to the timeline before exporting."
            case .actionCancelled:
                "The action was cancelled."
            }
        }
    }

    private static weak var model: EditorModel?
    private static var actionChain: Task<Void, Never>?

    static func connect(model: EditorModel) {
        self.model = model
    }

    static func resetForTesting() {
        model = nil
        actionChain = nil
    }

    static func perform(_ action: Action) async throws {
        guard let model else {
            throw RouterError.modelUnavailable
        }

        let predecessor = actionChain
        let actionTask = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            try await perform(action, on: model)
        }
        actionChain = Task {
            _ = await actionTask.result
        }
        try await withTaskCancellationHandler {
            try await actionTask.value
        } onCancel: {
            actionTask.cancel()
        }
    }

    private static func perform(_ action: Action, on model: EditorModel) async throws {
        switch action {
        case .newProject:
            let succeeded = await model.performNewProjectCommand()
            if !succeeded { throw RouterError.actionCancelled }
        case .importMedia:
            let succeeded = await model.performImportMediaCommand()
            if !succeeded { throw RouterError.actionCancelled }
        case .exportProject:
            guard model.totalDuration > 0 else {
                model.statusMessage = RouterError.emptyTimeline.errorDescription ?? ""
                throw RouterError.emptyTimeline
            }
            let succeeded = await model.performExportProjectCommand()
            if !succeeded { throw RouterError.actionCancelled }
        case .showDiagnostics:
            model.isDiagnosticsVisible = true
            model.statusMessage = "Diagnostics opened from Shortcuts."
        }
    }
}

struct NewLocalCutProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "New LocalCut Project"
    static let description = IntentDescription("Create a new LocalCut Studio project, prompting to save the current project if needed.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LocalCutAppIntentRouter.perform(.newProject)
        return .result()
    }
}

struct ImportMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Media in LocalCut"
    static let description = IntentDescription("Open LocalCut Studio and show the media import picker.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LocalCutAppIntentRouter.perform(.importMedia)
        return .result()
    }
}

struct ExportLocalCutProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Export LocalCut Project"
    static let description = IntentDescription("Open LocalCut Studio and show the export destination picker for the current timeline.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LocalCutAppIntentRouter.perform(.exportProject)
        return .result()
    }
}

struct ShowLocalCutDiagnosticsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show LocalCut Diagnostics"
    static let description = IntentDescription("Open LocalCut Studio's diagnostics panel.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LocalCutAppIntentRouter.perform(.showDiagnostics)
        return .result()
    }
}

struct LocalCutAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewLocalCutProjectIntent(),
            phrases: [
                "Create a new project in \(.applicationName)",
                "Start a new edit in \(.applicationName)"
            ],
            shortTitle: "New Project",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: ImportMediaIntent(),
            phrases: [
                "Import media in \(.applicationName)",
                "Add media to \(.applicationName)"
            ],
            shortTitle: "Import Media",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: ExportLocalCutProjectIntent(),
            phrases: [
                "Export my project in \(.applicationName)",
                "Render my timeline in \(.applicationName)"
            ],
            shortTitle: "Export Project",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: ShowLocalCutDiagnosticsIntent(),
            phrases: [
                "Show diagnostics in \(.applicationName)",
                "Open diagnostics in \(.applicationName)"
            ],
            shortTitle: "Diagnostics",
            systemImageName: "waveform.path.ecg"
        )
    }
}
