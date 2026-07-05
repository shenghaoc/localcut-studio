import AppIntents
import Foundation

/// Main-actor bridge from system-discovered App Intents into the live editor.
/// App Intents may be invoked while the app is foregrounded by Shortcuts, Siri,
/// or Spotlight; the actions stay thin and reuse the same model commands as the
/// menu bar so document prompts, panels, and validation remain consistent.
@MainActor
final class LocalCutAppIntentRouter {
    enum Action: String, CaseIterable, Sendable {
        case newProject
        case importMedia
        case exportProject
        case showDiagnostics
    }

    enum RouterError: LocalizedError, Equatable {
        case emptyTimeline
        case actionCancelled

        var errorDescription: String? {
            switch self {
            case .emptyTimeline:
                String(localized: "Add media to the timeline before exporting.")
            case .actionCancelled:
                String(localized: "The action was cancelled.")
            }
        }
    }

    private let model: EditorModel
    private var actionChain: Task<Void, Error>?

    init(model: EditorModel) {
        self.model = model
    }

    func perform(_ action: Action) async throws {
        let predecessor = actionChain
        let model = self.model
        let actionTask = Task { @MainActor in
            _ = await predecessor?.result
            try Task.checkCancellation()
            try await Self.perform(action, on: model)
        }
        actionChain = actionTask
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
            model.statusMessage = String(localized: "Diagnostics opened from Shortcuts.")
        }
    }
}

struct NewLocalCutProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "New LocalCut Project"
    static let description = IntentDescription("Create a new LocalCut Studio project, prompting to save the current project if needed.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency private var router: LocalCutAppIntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        try await router.perform(.newProject)
        return .result()
    }
}

struct ImportMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Media in LocalCut"
    static let description = IntentDescription("Open LocalCut Studio and show the media import picker.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency private var router: LocalCutAppIntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        try await router.perform(.importMedia)
        return .result()
    }
}

struct ExportLocalCutProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Export LocalCut Project"
    static let description = IntentDescription("Open LocalCut Studio and show the export destination picker for the current timeline.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency private var router: LocalCutAppIntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        try await router.perform(.exportProject)
        return .result()
    }
}

struct ShowLocalCutDiagnosticsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show LocalCut Diagnostics"
    static let description = IntentDescription("Open LocalCut Studio's diagnostics panel.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency private var router: LocalCutAppIntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        try await router.perform(.showDiagnostics)
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
