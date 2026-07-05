import AppIntents
import Testing
@testable import LocalCut_Studio

@MainActor
private final class AppIntentEventTracker {
    var events: [String] = []
}

@MainActor
struct AppIntentsTests {
    @Test func allShortcutActionsHaveShortcuts() {
        #expect(LocalCutAppIntentRouter.Action.allCases.count == LocalCutAppShortcuts.appShortcuts.count)
    }

    @Test func shortcutIntentsRunInImmediateForegroundMode() {
        #expect(NewLocalCutProjectIntent.supportedModes == .foreground(.immediate))
        #expect(ImportMediaIntent.supportedModes == .foreground(.immediate))
        #expect(ExportLocalCutProjectIntent.supportedModes == .foreground(.immediate))
        #expect(ShowLocalCutDiagnosticsIntent.supportedModes == .foreground(.immediate))
    }

    @Test func diagnosticsIntentRoutesToEditorModel() async throws {
        let model = EditorModel()
        let router = LocalCutAppIntentRouter(model: model)

        try await router.perform(.showDiagnostics)

        #expect(model.isDiagnosticsVisible)
        #expect(model.statusMessage == "Diagnostics opened from Shortcuts.")
    }

    @Test func emptyTimelineExportIntentThrowsAndUpdatesStatus() async {
        let model = EditorModel()
        let router = LocalCutAppIntentRouter(model: model)

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
        #expect(LocalCutAppIntentRouter.RouterError.emptyTimeline
                != LocalCutAppIntentRouter.RouterError.actionCancelled)
        #expect(LocalCutAppIntentRouter.RouterError.emptyTimeline
                != LocalCutAppIntentRouter.RouterError.panelCancelled)
    }

    @Test func actionChainSerializesConcurrentActions() async throws {
        let model = EditorModel()
        let tracker = AppIntentEventTracker()
        let router = LocalCutAppIntentRouter(model: model) { action, _ in
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
}
