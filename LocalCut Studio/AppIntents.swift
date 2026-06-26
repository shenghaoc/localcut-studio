import AppIntents

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

    private static weak var model: EditorModel?
    private static var pendingActions: [Action] = []

    static func connect(model: EditorModel) {
        self.model = model
        drainPendingActions()
    }

    static func disconnect() {
        model = nil
        pendingActions.removeAll()
    }

    static func perform(_ action: Action) {
        guard let model else {
            pendingActions.append(action)
            return
        }
        switch action {
        case .newProject:
            model.requestNew()
        case .importMedia:
            model.requestImport()
        case .exportProject:
            model.requestExport()
        case .showDiagnostics:
            model.isDiagnosticsVisible = true
            model.statusMessage = "Diagnostics opened from Shortcuts."
        }
    }

    private static func drainPendingActions() {
        let actions = pendingActions
        pendingActions.removeAll()
        for action in actions {
            perform(action)
        }
    }
}

struct NewLocalCutProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "New LocalCut Project"
    static let description = IntentDescription("Create a new LocalCut Studio project, prompting to save the current project if needed.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LocalCutAppIntentRouter.perform(.newProject)
        return .result()
    }
}

struct ImportMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Media in LocalCut"
    static let description = IntentDescription("Open LocalCut Studio and show the media import picker.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LocalCutAppIntentRouter.perform(.importMedia)
        return .result()
    }
}

struct ExportLocalCutProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Export LocalCut Project"
    static let description = IntentDescription("Open LocalCut Studio and show the export destination picker for the current timeline.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LocalCutAppIntentRouter.perform(.exportProject)
        return .result()
    }
}

struct ShowLocalCutDiagnosticsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show LocalCut Diagnostics"
    static let description = IntentDescription("Open LocalCut Studio's diagnostics panel.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LocalCutAppIntentRouter.perform(.showDiagnostics)
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
