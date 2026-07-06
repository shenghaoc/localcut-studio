import Foundation
import os

/// `@unchecked Sendable`: reconnect state (`attemptCount`, `etag`,
/// `iceServers`, `disconnectTime`) is behind `OSAllocatedUnfairLock`.
/// `clock` and `sleep` are immutable test-seam closures set once in `init`.
final class ReconnectController: @unchecked Sendable {
    nonisolated let maxAttempts: Int = 5
    private let backoffLadder: [Double] = [2, 4, 8, 16, 16]
    nonisolated let gracePeriod: TimeInterval = 3.0

    nonisolated let clock: @Sendable () -> TimeInterval
    nonisolated let sleep: @Sendable (TimeInterval) async throws -> Void

    private struct State {
        var attemptCount: Int = 0
        var etag: String?
        var iceServers: [String] = []
        var shouldTryIceRestart: Bool = true
        var disconnectTime: TimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    nonisolated init(
        clock: @escaping @Sendable () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { duration in
            try await Task.sleep(for: .seconds(duration))
        }
    ) {
        self.clock = clock
        self.sleep = sleep
    }

    nonisolated var attemptCount: Int { state.withLock { $0.attemptCount } }
    nonisolated var canAttemptReconnect: Bool { state.withLock { $0.attemptCount < maxAttempts } }
    nonisolated var shouldTryIceRestart: Bool { state.withLock { $0.shouldTryIceRestart } }
    nonisolated var currentETag: String? { state.withLock { $0.etag } }
    nonisolated var iceServers: [String] { state.withLock { $0.iceServers } }

    nonisolated var backoffDuration: TimeInterval {
        state.withLock { s in
            guard s.attemptCount > 0 else { return 0 }
            let index = min(s.attemptCount - 1, backoffLadder.count - 1)
            return backoffLadder[index]
        }
    }

    nonisolated func markDisconnected() {
        state.withLock { $0.disconnectTime = clock() }
    }

    nonisolated var isGracePeriodElapsed: Bool {
        state.withLock { s in
            guard let disconnectTime = s.disconnectTime else { return true }
            return clock() - disconnectTime >= gracePeriod
        }
    }

    nonisolated func waitForGracePeriod() async throws {
        guard !isGracePeriodElapsed else { return }
        let remaining: TimeInterval = state.withLock { s in
            guard let t = s.disconnectTime else { return 0.0 }
            return max(0, gracePeriod - (clock() - t))
        }
        if remaining > 0 { try await sleep(remaining) }
    }

    nonisolated func waitForBackoff() async throws {
        let duration = backoffDuration
        if duration > 0 { try await sleep(duration) }
    }

    nonisolated func advanceAttempt() { state.withLock { $0.attemptCount += 1 } }
    nonisolated func patchFailed() { state.withLock { $0.shouldTryIceRestart = false } }
    nonisolated func updateETag(_ newETag: String) { state.withLock { $0.etag = newETag } }
    nonisolated func resetETag() { state.withLock { s in s.etag = nil; s.shouldTryIceRestart = true } }
    nonisolated func updateIceServers(_ servers: [String]) { state.withLock { $0.iceServers = servers } }

    nonisolated func reset() {
        state.withLock { s in
            s.attemptCount = 0
            s.etag = nil
            s.iceServers = []
            s.shouldTryIceRestart = true
            s.disconnectTime = nil
        }
    }
}
