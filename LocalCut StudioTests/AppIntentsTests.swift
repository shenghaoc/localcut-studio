import AppIntents
import Testing
@testable import LocalCut_Studio

@MainActor
struct AppIntentsTests {
    @Test func allShortcutActionsHaveShortcuts() {
        #expect(LocalCutAppIntentRouter.Action.allCases.count == LocalCutAppShortcuts.appShortcuts.count)
    }

    @Test func diagnosticsIntentRoutesToEditorModel() async throws {
        LocalCutAppIntentRouter.resetForTesting()
        let model = EditorModel()
        LocalCutAppIntentRouter.connect(model: model)

        try await LocalCutAppIntentRouter.perform(.showDiagnostics)

        #expect(model.isDiagnosticsVisible)
        #expect(model.statusMessage == "Diagnostics opened from Shortcuts.")
    }

    @Test func intentWithoutEditorModelThrows() async {
        LocalCutAppIntentRouter.resetForTesting()

        do {
            try await LocalCutAppIntentRouter.perform(.showDiagnostics)
            Issue.record("Expected modelUnavailable")
        } catch LocalCutAppIntentRouter.RouterError.modelUnavailable {
        } catch {
            Issue.record("Expected modelUnavailable, got \(error)")
        }
    }

    @Test func emptyTimelineExportIntentThrowsAndUpdatesStatus() async {
        LocalCutAppIntentRouter.resetForTesting()
        let model = EditorModel()
        LocalCutAppIntentRouter.connect(model: model)

        do {
            try await LocalCutAppIntentRouter.perform(.exportProject)
            Issue.record("Expected emptyTimeline")
        } catch LocalCutAppIntentRouter.RouterError.emptyTimeline {
            #expect(model.statusMessage == "Add media to the timeline before exporting.")
        } catch {
            Issue.record("Expected emptyTimeline, got \(error)")
        }
    }
}
