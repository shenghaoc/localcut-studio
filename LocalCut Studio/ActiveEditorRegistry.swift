import Foundation

/// Tracks readiness of the single process-wide editor window for App Intents.
///
/// LocalCut's GUI does not support independent document models. This registry
/// only answers "is the editor window available?" so cold-launch Shortcuts can
/// wait for the window instead of failing with a misleading "open a project"
/// error. It is not a multi-document identity map.
@MainActor
final class ActiveEditorRegistry {
    enum WaitError: Error, Equatable, Sendable {
        case timedOut
    }

    /// Monotonic generation bumped whenever the editor becomes ready or
    /// unavailable. Queued intents capture a generation so a window that closes
    /// mid-queue fails with `targetWindowClosed` instead of silently waiting
    /// for a later reappearance.
    private(set) var generation: UInt64 = 0

    private weak var editor: EditorModel?
    private var isReady = false
    private var waiters: [UUID: CheckedContinuation<UInt64, Error>] = [:]

    /// Marks the editor window ready for App Intent routing. Called from the
    /// editor view lifecycle and key-window activation. Re-marking the same
    /// ready editor is a no-op so key-window churn does not invalidate a
    /// queued intent's captured generation.
    func markReady(_ model: EditorModel) {
        if isReady, editor === model {
            return
        }
        editor = model
        isReady = true
        generation &+= 1
        let waiters = self.waiters
        self.waiters.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(returning: generation)
        }
    }

    /// Marks the editor window unavailable after it disappears. Queued intents
    /// that captured an earlier ready generation fail rather than retargeting.
    func markUnavailable(_ model: EditorModel) {
        guard editor == nil || editor === model else { return }
        editor = nil
        if isReady {
            isReady = false
            generation &+= 1
        }
    }

    /// Snapshot used when an intent is enqueued so cold-launch waits can be
    /// distinguished from "the window closed before this action ran".
    struct Capture: Sendable {
        let generation: UInt64
        let wasReady: Bool
    }

    func capture() -> Capture {
        Capture(generation: generation, wasReady: isReady && editor != nil)
    }

    /// Returns the live editor when the window is currently ready.
    func readyEditor() -> EditorModel? {
        guard isReady else { return nil }
        return editor
    }

    /// Resolves the editor for a previously captured ready generation.
    /// Returns `nil` when that window is no longer available.
    func editor(matchingGeneration generation: UInt64) -> EditorModel? {
        guard isReady, self.generation == generation else { return nil }
        return editor
    }

    /// Waits until the editor window becomes ready, the task is cancelled, or
    /// `timeout` elapses. Uses an injected clock so tests stay deterministic.
    func waitUntilReady(
        timeout: Duration,
        clock: ContinuousClock = ContinuousClock()
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        if readyEditor() != nil { return generation }

        return try await withThrowingTaskGroup(of: UInt64.self) { group in
            group.addTask {
                try await clock.sleep(for: timeout)
                throw WaitError.timedOut
            }
            group.addTask {
                try await self.waitForReadiness()
            }
            defer { group.cancelAll() }
            guard let readyGeneration = try await group.next() else {
                throw CancellationError()
            }
            return readyGeneration
        }
    }

    /// Suspends one structured child until readiness or cancellation. The
    /// sibling timeout task is cancelled as soon as this waiter finishes.
    private func waitForReadiness() async throws -> UInt64 {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt64, Error>) in
                // A task group may cancel this child before the MainActor gets
                // to run its continuation body. Do not add an already-cancelled
                // waiter because its cancellation handler has already run.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if readyEditor() != nil {
                    continuation.resume(returning: generation)
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                guard let pending = self.waiters.removeValue(forKey: waiterID) else { return }
                pending.resume(throwing: CancellationError())
            }
        }
    }
}
