import Testing
import Foundation
@testable import LocalCut_Studio

// Tests for EditorModel.inspectorVisible — a UserDefaults-persisted flag that
// the Show Inspector menu / toolbar / collapsed-rail share as one source of
// truth. The injection seam (`init(defaultsStore:)`) lets these tests verify
// the round-trip without polluting the user's preferences database.
//
// Locks the invariant that a regression decoupling the bool from
// SplitViewAutosaveConfigurator's `isEnabled` would re-introduce the
// saved-width clobber on collapse.

@MainActor
@Suite("EditorModel.inspectorVisible persistence")
struct InspectorVisiblePersistenceTests {

    /// Fresh, isolated UserDefaults suite per test so tests don't share state
    /// with each other or with `.standard`.
    private static func freshDefaults() -> UserDefaults {
        let suite = "test.localcut.inspectorVisible.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("Defaults to true when nothing is stored")
    func defaultsToTrueWhenAbsent() {
        let store = Self.freshDefaults()
        let model = EditorModel(defaultsStore: store)
        #expect(model.inspectorVisible == true)
    }

    @Test("A previously stored false survives a fresh model")
    func falseRoundTripsAcrossInstances() {
        let store = Self.freshDefaults()
        do {
            let model = EditorModel(defaultsStore: store)
            model.inspectorVisible = false
        }
        // A fresh model wired to the same store reads the persisted value.
        let model2 = EditorModel(defaultsStore: store)
        #expect(model2.inspectorVisible == false)
    }

    @Test("Flipping the property writes back to the injected store, not .standard")
    func writesGoToInjectedStore() {
        let store = Self.freshDefaults()
        let model = EditorModel(defaultsStore: store)

        model.inspectorVisible = false
        #expect(store.bool(forKey: EditorModel.inspectorVisibleKey) == false)

        model.inspectorVisible = true
        #expect(store.bool(forKey: EditorModel.inspectorVisibleKey) == true)
    }

    @Test("Distinguishes 'never set' from 'explicitly false'")
    func absentSentinelIsDistinctFromExplicitFalse() {
        // The bool(forKey:) fallback would silently return false for both
        // states; using object(forKey:) as? Bool preserves the distinction.
        let store = Self.freshDefaults()
        #expect(store.object(forKey: EditorModel.inspectorVisibleKey) == nil)
        let modelA = EditorModel(defaultsStore: store)
        #expect(modelA.inspectorVisible == true)              // default

        modelA.inspectorVisible = false
        #expect(store.object(forKey: EditorModel.inspectorVisibleKey) as? Bool == false)
        let modelB = EditorModel(defaultsStore: store)
        #expect(modelB.inspectorVisible == false)             // honors explicit false
    }
}
