import AppIntents
import Testing
@testable import LocalCut_Studio

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
}
