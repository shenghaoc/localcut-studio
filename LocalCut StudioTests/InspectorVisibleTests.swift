import Testing
@testable import LocalCut_Studio

/// Editor readiness for App Intents. The GUI has one process-wide editor model;
/// this suite only covers window readiness and generation stability.
@MainActor
@Suite("Editor window readiness")
struct ActiveEditorRegistryTests {
    @Test func markReadyExposesTheEditor() {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()

        registry.markReady(model)

        #expect(registry.readyEditor() === model)
        #expect(registry.capture().wasReady)
    }

    @Test func reMarkingTheSameEditorKeepsGenerationStable() {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()

        registry.markReady(model)
        let generation = registry.generation
        registry.markReady(model)

        #expect(registry.generation == generation)
        #expect(registry.editor(matchingGeneration: generation) === model)
    }

    @Test func markUnavailableClearsReadiness() {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()

        registry.markReady(model)
        let generation = registry.generation
        registry.markUnavailable(model)

        #expect(registry.readyEditor() == nil)
        #expect(registry.editor(matchingGeneration: generation) == nil)
        #expect(!registry.capture().wasReady)
    }

    @Test func waitUntilReadyResumesWhenEditorAppears() async throws {
        let model = EditorModel()
        let registry = ActiveEditorRegistry()

        let waiter = Task {
            try await registry.waitUntilReady(timeout: .seconds(2))
        }
        await Task.yield()
        registry.markReady(model)
        _ = try await waiter.value
        #expect(registry.readyEditor() === model)
    }

    @Test func cancellationBeforeWaiterRegistrationDoesNotBlockLaterWaits() async {
        let registry = ActiveEditorRegistry()
        let cancelledWait = Task {
            try await registry.waitUntilReady(timeout: .seconds(1))
        }
        cancelledWait.cancel()

        let cancelledPromptly = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await cancelledWait.value
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
        #expect(cancelledPromptly)

        do {
            _ = try await registry.waitUntilReady(timeout: .milliseconds(20))
            Issue.record("Expected the later readiness wait to time out.")
        } catch ActiveEditorRegistry.WaitError.timedOut {
        } catch {
            Issue.record("Expected WaitError.timedOut, got \(error)")
        }
    }
}
