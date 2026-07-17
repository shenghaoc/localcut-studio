import AppIntents
import AppKit
import Testing
@testable import LocalCut_Studio

@MainActor
private final class AppIntentEventTracker {
    var events: [String] = []
}

private actor AppIntentStartSignal {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        started = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private actor AppIntentReleaseGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private enum AppIntentCancellationOutcome {
    case cancelled
    case completed
    case timedOut
}

@MainActor
struct AppIntentsTests {
    private func readyRouting(_ model: EditorModel) -> (ActiveEditorRegistry, LocalCutAppIntentRouter) {
        let registry = ActiveEditorRegistry()
        registry.markReady(model)
        return (registry, LocalCutAppIntentRouter(editorRegistry: registry))
    }

    @Test func allShortcutActionsHaveShortcuts() {
        #expect(LocalCutAppIntentRouter.Action.allCases.count == LocalCutAppShortcuts.appShortcuts.count)
    }

    @Test func shortcutIntentsRunInImmediateForegroundMode() {
        #expect(NewLocalCutProjectIntent.supportedModes == .foreground(.immediate))
        #expect(ImportMediaIntent.supportedModes == .foreground(.immediate))
        #expect(ExportLocalCutProjectIntent.supportedModes == .foreground(.immediate))
        #expect(ShowLocalCutDiagnosticsIntent.supportedModes == .foreground(.immediate))
    }

    @Test func diagnosticsIntentRoutesToReadyEditor() async throws {
        let model = EditorModel()
        let (_, router) = readyRouting(model)

        try await router.perform(.showDiagnostics)

        #expect(model.isDiagnosticsVisible)
        #expect(model.statusMessage == "Diagnostics opened from Shortcuts.")
    }

    @Test func coldLaunchNewProjectWaitsForEditorReadiness() async throws {
        let model = EditorModel()
        model.project.name = "Dirty"
        model.isDirty = true
        let registry = ActiveEditorRegistry()
        let tracker = AppIntentEventTracker()
        let router = LocalCutAppIntentRouter(editorRegistry: registry) { action, routed in
            tracker.events.append("\(action.rawValue)-\(routed === model ? "model" : "other")")
            if action == .newProject {
                // Confirm-save path would prompt; inject by using a ready model
                // that is not dirty after markReady in the outer test.
            }
        }

        let intent = Task {
            try await router.perform(.newProject)
        }
        await Task.yield()
        #expect(tracker.events.isEmpty)

        registry.markReady(model)
        try await intent.value

        #expect(tracker.events == ["newProject-model"])
    }

    @Test func coldLaunchDiagnosticsWaitsForEditorReadiness() async throws {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()
        let router = LocalCutAppIntentRouter(editorRegistry: registry)

        let intent = Task {
            try await router.perform(.showDiagnostics)
        }
        await Task.yield()
        #expect(!model.isDiagnosticsVisible)

        registry.markReady(model)
        try await intent.value

        #expect(model.isDiagnosticsVisible)
    }

    @Test func coldLaunchImportWaitsForEditorReadiness() async throws {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()
        let started = AppIntentStartSignal()
        let router = LocalCutAppIntentRouter(editorRegistry: registry) { action, _ in
            #expect(action == .importMedia)
            await started.markStarted()
        }

        let intent = Task {
            try await router.perform(.importMedia)
        }
        await Task.yield()

        registry.markReady(model)
        await started.waitUntilStarted()
        try await intent.value
    }

    @Test func queuedColdLaunchActionFailsAfterAwakenedWindowIsReplaced() async throws {
        let awakenedModel = EditorModel()
        let replacementModel = EditorModel()
        let registry = ActiveEditorRegistry()
        let firstStarted = AppIntentStartSignal()
        let releaseFirst = AppIntentReleaseGate()
        let tracker = AppIntentEventTracker()
        let router = LocalCutAppIntentRouter(editorRegistry: registry) { action, routed in
            if action == .newProject {
                await firstStarted.markStarted()
                await releaseFirst.wait()
            }
            tracker.events.append(
                "\(action.rawValue)-\(routed === awakenedModel ? "awakened" : "replacement")")
        }

        let first = Task { try await router.perform(.newProject) }
        let queued = Task { try await router.perform(.importMedia) }
        await Task.yield()

        registry.markReady(awakenedModel)
        await firstStarted.waitUntilStarted()
        registry.markUnavailable(awakenedModel)
        registry.markReady(replacementModel)
        await releaseFirst.open()

        try await first.value
        do {
            try await queued.value
            Issue.record("Expected targetWindowClosed.")
        } catch LocalCutAppIntentRouter.RouterError.targetWindowClosed {
        } catch {
            Issue.record("Expected targetWindowClosed, got \(error)")
        }
        #expect(tracker.events == ["newProject-awakened"])
    }

    @Test func coldLaunchExportWithEmptyTimelineThrows() async throws {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()
        let router = LocalCutAppIntentRouter(editorRegistry: registry)

        let intent = Task {
            try await router.perform(.exportProject)
        }
        await Task.yield()
        registry.markReady(model)

        do {
            try await intent.value
            Issue.record("Expected emptyTimeline")
        } catch LocalCutAppIntentRouter.RouterError.emptyTimeline {
            #expect(model.statusMessage == "Add media to the timeline before exporting.")
        } catch {
            Issue.record("Expected emptyTimeline, got \(error)")
        }
    }

    @Test func readinessWaitTimesOutWithEditorUnavailable() async {
        let registry = ActiveEditorRegistry()
        let router = LocalCutAppIntentRouter(
            editorRegistry: registry,
            readinessTimeout: .milliseconds(30)
        )

        do {
            try await router.perform(.showDiagnostics)
            Issue.record("Expected editorUnavailable.")
        } catch LocalCutAppIntentRouter.RouterError.editorUnavailable {
        } catch {
            Issue.record("Expected editorUnavailable, got \(error)")
        }
    }

    @Test func cancellationWhileWaitingForReadinessFinishesPromptly() async throws {
        let registry = ActiveEditorRegistry()
        let router = LocalCutAppIntentRouter(
            editorRegistry: registry,
            readinessTimeout: .seconds(1)
        )

        let intent = Task {
            try await router.perform(.importMedia)
        }
        await Task.yield()
        intent.cancel()

        do {
            try await intent.value
            Issue.record("Expected CancellationError.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func emptyTimelineExportIntentThrowsAndUpdatesStatus() async {
        let model = EditorModel()
        let (_, router) = readyRouting(model)

        do {
            try await router.perform(.exportProject)
            Issue.record("Expected emptyTimeline")
        } catch LocalCutAppIntentRouter.RouterError.emptyTimeline {
            #expect(model.statusMessage == "Add media to the timeline before exporting.")
        } catch {
            Issue.record("Expected emptyTimeline, got \(error)")
        }
    }

    @Test func routerErrorTypesAreDistinct() {
        #expect(LocalCutAppIntentRouter.RouterError.panelCancelled
                != LocalCutAppIntentRouter.RouterError.actionCancelled)
        #expect(LocalCutAppIntentRouter.RouterError.actionFailed
                != LocalCutAppIntentRouter.RouterError.actionCancelled)
        #expect(LocalCutAppIntentRouter.RouterError.emptyTimeline
                != LocalCutAppIntentRouter.RouterError.actionCancelled)
        #expect(LocalCutAppIntentRouter.RouterError.emptyTimeline
                != LocalCutAppIntentRouter.RouterError.panelCancelled)
        #expect(LocalCutAppIntentRouter.RouterError.editorUnavailable
                != LocalCutAppIntentRouter.RouterError.targetWindowClosed)
    }

    @Test func failedCommandOutcomeMapsToActionFailedRouterError() {
        do {
            try LocalCutAppIntentRouter.throwIfNeeded(.failed)
            Issue.record("Expected actionFailed.")
        } catch LocalCutAppIntentRouter.RouterError.actionFailed {
        } catch {
            Issue.record("Expected actionFailed, got \(error)")
        }
    }

    @Test func actionChainSerializesAgainstSingleEditor() async throws {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()
        registry.markReady(model)
        let tracker = AppIntentEventTracker()
        let router = LocalCutAppIntentRouter(editorRegistry: registry) { action, _ in
            tracker.events.append("start-\(action.rawValue)")
            try await Task.sleep(for: .milliseconds(10))
            tracker.events.append("end-\(action.rawValue)")
        }

        let first = Task { try await router.perform(.newProject) }
        await Task.yield()
        let second = Task { try await router.perform(.importMedia) }
        try await first.value
        try await second.value

        #expect(tracker.events == [
            "start-newProject",
            "end-newProject",
            "start-importMedia",
            "end-importMedia"
        ])
    }

    @Test func queuedActionAfterWindowCloseThrowsWithoutRetargeting() async throws {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()
        registry.markReady(model)
        let firstStarted = AppIntentStartSignal()
        let releaseFirst = AppIntentReleaseGate()
        let tracker = AppIntentEventTracker()
        let router = LocalCutAppIntentRouter(editorRegistry: registry) { action, _ in
            if action == .newProject {
                await firstStarted.markStarted()
                await releaseFirst.wait()
            }
            tracker.events.append(action.rawValue)
        }

        let first = Task { try await router.perform(.newProject) }
        await firstStarted.waitUntilStarted()
        let queued = Task { try await router.perform(.importMedia) }
        // Capture happens synchronously at enqueue; yield so the queued task
        // is waiting on the predecessor before the window goes away.
        await Task.yield()
        registry.markUnavailable(model)
        await releaseFirst.open()

        try await first.value
        do {
            try await queued.value
            Issue.record("Expected targetWindowClosed.")
        } catch LocalCutAppIntentRouter.RouterError.targetWindowClosed {
        } catch {
            Issue.record("Expected targetWindowClosed, got \(error)")
        }
        #expect(tracker.events == ["newProject"])
    }

    @Test func cancelledActionDoesNotWaitForLongRunningPredecessor() async throws {
        let model = EditorModel()
        let (registry, _) = readyRouting(model)
        let started = AppIntentStartSignal()
        let router = LocalCutAppIntentRouter(editorRegistry: registry) { action, _ in
            if action == .newProject {
                await started.markStarted()
                try await Task.sleep(for: .seconds(60))
            }
        }

        let first = Task { try await router.perform(.newProject) }
        await started.waitUntilStarted()
        let second = Task { try await router.perform(.importMedia) }
        await Task.yield()
        second.cancel()

        let outcome = await withTaskGroup(of: AppIntentCancellationOutcome.self) { group in
            group.addTask {
                do {
                    try await second.value
                    return .completed
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    Issue.record("Expected CancellationError, got \(error)")
                    return .completed
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return .timedOut
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }

        #expect(outcome == .cancelled)
        first.cancel()
        do {
            try await first.value
            Issue.record("Expected first action to cancel during cleanup.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError for first action, got \(error)")
        }
        do {
            try await second.value
            Issue.record("Expected second action to throw CancellationError.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError for second action, got \(error)")
        }
    }

    @Test func newProjectCommandCancelledAfterPromptDoesNotResetDocument() async {
        let model = EditorModel()
        let started = AppIntentStartSignal()
        let tracker = AppIntentEventTracker()
        let task = Task {
            await model.performNewProjectCommand(
                confirmSave: {
                    await started.markStarted()
                    try? await Task.sleep(for: .seconds(60))
                    return true
                },
                resetDocument: {
                    tracker.events.append("reset")
                })
        }

        await started.waitUntilStarted()
        task.cancel()

        let outcome = await task.value

        #expect(outcome == .actionCancelled)
        #expect(tracker.events.isEmpty)
    }

    @Test func exportProjectCommandPropagatesQueueFailure() async {
        let model = EditorModel()
        model.totalDuration = 1
        let outputURL = URL(filePath: "/private/tmp/app-intents-export-failure.mov")

        let outcome = await model.performExportProjectCommand(
            presentPanel: {
                (.OK, outputURL)
            },
            exportProject: { _ in
                model.statusMessage = "Could not access \(outputURL.lastPathComponent)."
                return .failed
            })

        #expect(outcome == .failed)
        #expect(model.statusMessage == "Could not access \(outputURL.lastPathComponent).")
    }

    @Test func importMediaCommandPropagatesImportFailure() async {
        let model = EditorModel()
        let inputURL = URL(filePath: "/private/tmp/app-intents-import-failure.mov")

        let outcome = await model.performImportMediaCommand(
            presentPanel: {
                (.OK, [inputURL])
            },
            importMediaAction: { _ in
                model.statusMessage = "Could not import \(inputURL.lastPathComponent): metadata unavailable"
                return .failed
            })

        #expect(outcome == .failed)
        #expect(model.statusMessage == "Could not import \(inputURL.lastPathComponent): metadata unavailable")
    }

    @Test func importPanelCancellationPreservesStatus() async {
        let model = EditorModel()
        model.statusMessage = "Ready to import."

        let outcome = await model.performImportMediaCommand(
            presentPanel: {
                (.cancel, [])
            },
            importMediaAction: { _ in
                Issue.record("Import action should not run after panel cancellation.")
                return .completed
            })

        #expect(outcome == .panelCancelled)
        #expect(model.statusMessage == "Ready to import.")
    }

    @Test func exportPanelCancellationPreservesStatus() async {
        let model = EditorModel()
        model.totalDuration = 1
        model.statusMessage = "Ready to export."

        let outcome = await model.performExportProjectCommand(
            presentPanel: {
                (.cancel, nil)
            },
            exportProject: { _ in
                Issue.record("Export action should not run after panel cancellation.")
                return .completed
            })

        #expect(outcome == .panelCancelled)
        #expect(model.statusMessage == "Ready to export.")
    }

    @Test func exportCoordinatorPropagatesQueueRejection() async {
        let model = EditorModel()
        let outputURL = URL(filePath: "/private/tmp/app-intents-export-queue-rejection.mov")
        let outcome = await ExportCoordinator().export(to: outputURL, model: model) { _ in
            .failed("Output destination unavailable.")
        }

        #expect(outcome == .failed)
        #expect(model.statusMessage == "Output destination unavailable.")
    }
}
