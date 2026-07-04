import Foundation
import os

final class ReconnectController: @unchecked Sendable {
    let maxAttempts: Int = 5
    private let backoffLadder: [Double] = [2, 4, 8, 16, 16]
    let gracePeriod: TimeInterval = 3.0

    nonisolated(unsafe) var clock: @Sendable () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    nonisolated(unsafe) var sleep: @Sendable (TimeInterval) async throws -> Void = { duration in
        try await Task.sleep(for: .seconds(duration))
    }

    private struct State {
        var attemptCount: Int = 0
        var etag: String?
        var iceServers: [String] = []
        var shouldTryIceRestart: Bool = true
        var disconnectTime: TimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    nonisolated init() {}

    var attemptCount: Int { state.withLock { $0.attemptCount } }
    var canAttemptReconnect: Bool { state.withLock { $0.attemptCount < maxAttempts } }
    var shouldTryIceRestart: Bool { state.withLock { $0.shouldTryIceRestart } }
    var currentETag: String? { state.withLock { $0.etag } }
    var iceServers: [String] { state.withLock { $0.iceServers } }

    var backoffDuration: TimeInterval {
        state.withLock { s in
            guard s.attemptCount > 0 else { return 0 }
            let index = min(s.attemptCount - 1, backoffLadder.count - 1)
            return backoffLadder[index]
        }
    }

    func markDisconnected() {
        state.withLock { $0.disconnectTime = clock() }
    }

    var isGracePeriodElapsed: Bool {
        state.withLock { s in
            guard let disconnectTime = s.disconnectTime else { return true }
            return clock() - disconnectTime >= gracePeriod
        }
    }

    func waitForGracePeriod() async throws {
        guard !isGracePeriodElapsed else { return }
        let remaining: TimeInterval = state.withLock { s in
            guard let t = s.disconnectTime else { return 0.0 }
            return max(0, gracePeriod - (clock() - t))
        }
        if remaining > 0 { try await sleep(remaining) }
    }

    func waitForBackoff() async throws {
        let duration = backoffDuration
        if duration > 0 { try await sleep(duration) }
    }

    func advanceAttempt() { state.withLock { $0.attemptCount += 1 } }
    func patchFailed() { state.withLock { $0.shouldTryIceRestart = false } }
    func updateETag(_ newETag: String) { state.withLock { $0.etag = newETag } }
    func resetETag() { state.withLock { s in s.etag = nil; s.shouldTryIceRestart = true } }
    func updateIceServers(_ servers: [String]) { state.withLock { $0.iceServers = servers } }

    func reset() {
        state.withLock { s in
            s.attemptCount = 0
            s.etag = nil
            s.iceServers = []
            s.shouldTryIceRestart = true
            s.disconnectTime = nil
        }
    }
}
