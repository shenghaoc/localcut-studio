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

    enum RouterError: LocalizedError, Equatable, Sendable {
        case noActiveDocument
        case targetDocumentClosed
        case emptyTimeline
        case actionCancelled
        case actionFailed
        case panelCancelled

        var errorDescription: String? {
            switch self {
            case .noActiveDocument:
                String(localized: "Open a LocalCut project before running this action.")
            case .targetDocumentClosed:
                String(localized: "The LocalCut project closed before the action could run.")
            case .emptyTimeline:
                String(localized: "Add media to the timeline before exporting.")
            case .actionCancelled:
                String(localized: "The action was cancelled.")
            case .actionFailed:
                String(localized: "The action could not be completed.")
            case .panelCancelled:
                String(localized: "The panel was dismissed.")
            }
        }
    }

    /// Holds the queue barrier on `@MainActor` so queued actions serialize
    /// without sharing raw tasks across actor boundaries.
    @MainActor
    private final class TaskReference: Sendable {
        let barrier: ActionBarrier

        init(finished: Bool = false) {
            barrier = ActionBarrier(finished: finished)
        }
    }

    private actor ActionBarrier {
        private var isFinished: Bool
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(finished: Bool = false) {
            isFinished = finished
        }

        func wait() async {
            guard !isFinished else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func finish() {
            guard !isFinished else { return }
            isFinished = true
            let waiters = self.waiters
            self.waiters.removeAll()
            for continuation in waiters {
                continuation.resume()
            }
        }
    }

    private actor ActionResult {
        private var result: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        func wait() async throws {
            if let result {
                try result.get()
                return
            }
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(with result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }

        func cancel() {
            finish(with: .failure(CancellationError()))
        }
    }

    private let documentRegistry: ActiveDocumentRegistry
    private let routeAction: @MainActor @Sendable (Action, EditorModel) async throws -> Void
    private var actionChain = TaskReference(finished: true)

    init(
        documentRegistry: ActiveDocumentRegistry,
        routeAction: @escaping @MainActor @Sendable (Action, EditorModel) async throws -> Void = LocalCutAppIntentRouter.route
    ) {
        self.documentRegistry = documentRegistry
        self.routeAction = routeAction
    }

    func perform(_ action: Action) async throws {
        guard let target = documentRegistry.activeTarget() else {
            throw RouterError.noActiveDocument
        }
        let predecessorRef = actionChain
        let currentRef = TaskReference()
        actionChain = currentRef

        let targetToken = target.token
        let documentRegistry = self.documentRegistry
        let routeAction = self.routeAction
        let result = ActionResult()
        let predecessorBarrier = predecessorRef.barrier
        let currentBarrier = currentRef.barrier
        let actionTask = Task { @MainActor in
            await predecessorBarrier.wait()
            do {
                try Task.checkCancellation()
                guard let model = documentRegistry.model(for: targetToken) else {
                    throw RouterError.targetDocumentClosed
                }
                try await routeAction(action, model)
                await result.finish(with: .success(()))
            } catch {
                await result.finish(with: .failure(error))
            }
            await currentBarrier.finish()
        }
        try await withTaskCancellationHandler {
            try await result.wait()
        } onCancel: {
            actionTask.cancel()
            Task {
                await result.cancel()
            }
            Task { @MainActor in
                if actionChain === currentRef {
                    actionChain = predecessorRef
                }
            }
        }
    }

    private static func route(_ action: Action, on model: EditorModel) async throws {
        switch action {
        case .newProject:
            try throwIfNeeded(await model.performNewProjectCommand())
        case .importMedia:
            try throwIfNeeded(await model.performImportMediaCommand())
        case .exportProject:
            // check totalDuration before calling command to throw the correct error type
            guard model.totalDuration > 0 else {
                model.statusMessage = RouterError.emptyTimeline.errorDescription ?? ""
                throw RouterError.emptyTimeline
            }
            try throwIfNeeded(await model.performExportProjectCommand())
        case .showDiagnostics:
            model.isDiagnosticsVisible = true
            model.statusMessage = String(localized: "Diagnostics opened from Shortcuts.")
        }
    }

    static func throwIfNeeded(_ outcome: EditorCommandOutcome) throws {
        switch outcome {
        case .completed:
            return
        case .actionCancelled:
            throw RouterError.actionCancelled
        case .failed:
            throw RouterError.actionFailed
        case .panelCancelled:
            throw RouterError.panelCancelled
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
