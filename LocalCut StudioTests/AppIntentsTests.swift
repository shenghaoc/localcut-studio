import AppIntents
import Testing
@testable import LocalCut_Studio

@MainActor
struct AppIntentsTests {
    @Test func allShortcutActionsHaveShortcuts() {
        #expect(LocalCutAppIntentRouter.Action.allCases.count == LocalCutAppShortcuts.appShortcuts.count)
    }

    @Test func queuedIntentRunsWhenEditorConnects() {
        LocalCutAppIntentRouter.disconnect()
        LocalCutAppIntentRouter.perform(.showDiagnostics)

        let model = EditorModel()
        LocalCutAppIntentRouter.connect(model: model)

        #expect(model.isDiagnosticsVisible)
        #expect(model.statusMessage == "Diagnostics opened from Shortcuts.")
    }

    @Test func diagnosticsIntentRoutesToEditorModel() {
        let model = EditorModel()
        LocalCutAppIntentRouter.connect(model: model)

        LocalCutAppIntentRouter.perform(.showDiagnostics)

        #expect(model.isDiagnosticsVisible)
        #expect(model.statusMessage == "Diagnostics opened from Shortcuts.")
    }
}
