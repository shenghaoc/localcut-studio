import Testing
@testable import LocalCut_Studio

/// Window presentation state now belongs to SwiftUI scene storage. The unit
/// boundary we can exercise deterministically is focused document routing: a
/// key window must resolve to its own editor, and a closed token must never be
/// redirected to another open editor.
@MainActor
@Suite("Active document routing")
struct ActiveDocumentRegistryTests {
    @Test func mostRecentlyActivatedEditorIsTheActiveTarget() {
        let first = EditorModel()
        let second = EditorModel()
        let registry = ActiveDocumentRegistry()

        registry.register(first)
        registry.register(second)
        registry.activate(first)

        let target = registry.activeTarget()
        #expect(target?.model === first)
    }

    @Test func registeringTheSameEditorKeepsItsTokenStable() {
        let model = EditorModel()
        let registry = ActiveDocumentRegistry()

        let original = registry.register(model)
        let repeatRegistration = registry.register(model)

        #expect(original == repeatRegistration)
    }

    @Test func closedTokenDoesNotRetargetToAnotherEditor() {
        let first = EditorModel()
        let second = EditorModel()
        let registry = ActiveDocumentRegistry()

        let firstToken = registry.register(first)
        registry.register(second)
        registry.activate(first)
        registry.unregister(first)

        #expect(registry.model(for: firstToken) == nil)
        #expect(registry.activeTarget()?.model === second)
    }

    @Test func unregisteringTheLastEditorLeavesNoActiveTarget() {
        let model = EditorModel()
        let registry = ActiveDocumentRegistry()

        registry.register(model)
        registry.unregister(model)

        #expect(registry.activeTarget() == nil)
    }
}
