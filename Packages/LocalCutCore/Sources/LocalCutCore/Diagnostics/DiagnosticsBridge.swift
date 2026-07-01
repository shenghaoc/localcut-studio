import Foundation
import os

/// Thread-safe handoff between the AVFoundation render queue and the
/// main-actor `DiagnosticsAgent`. All state is guarded by `OSAllocatedUnfairLock`.
public final class DiagnosticsBridge: Sendable {

    public static let shared = DiagnosticsBridge()

    public static let renderTimeCapacity = 256

    public init() {}

    public struct Snapshot: Sendable {
        public let renderTimes: [Double]
        public let lastRenderTime: Double
        public let decoderCount: Int
        public let totalFrameCount: Int
        /// Phase 45: current encoder lease count.
        public let encoderLeaseCount: Int
        /// Phase 45: maximum encoder budget.
        public let encoderBudgetMax: Int
        /// Phase 45: encoder lease ledger (consumer labels).
        public let encoderLedger: [String]
    }

    private struct State {
        var renderTimes: [Double] = []
        var lastRenderTime: Double = 0
        var decoderCount: Int = 0
        var totalFrameCount: Int = 0
        var encoderLeaseCount: Int = 0
        var encoderBudgetMax: Int = 0
        var encoderLedger: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let enabledFlag = OSAllocatedUnfairLock(initialState: false)

    public var isEnabled: Bool {
        enabledFlag.withLock { $0 }
    }

    public func setEnabled(_ value: Bool) {
        enabledFlag.withLock { $0 = value }
    }

    public func recordRenderTime(_ seconds: Double) {
        state.withLock { s in
            s.renderTimes.append(seconds)
            s.lastRenderTime = seconds
            s.totalFrameCount &+= 1
            let cap = Self.renderTimeCapacity
            if s.renderTimes.count > cap {
                s.renderTimes.removeFirst(s.renderTimes.count - cap)
            }
        }
    }

    public func setDecoderCount(_ count: Int) {
        state.withLock { $0.decoderCount = count }
    }

    public func snapshot() -> Snapshot {
        state.withLock { s in
            Snapshot(renderTimes: s.renderTimes,
                     lastRenderTime: s.lastRenderTime,
                     decoderCount: s.decoderCount,
                     totalFrameCount: s.totalFrameCount,
                     encoderLeaseCount: s.encoderLeaseCount,
                     encoderBudgetMax: s.encoderBudgetMax,
                     encoderLedger: s.encoderLedger)
        }
    }

    /// Phase 45: updates encoder budget diagnostics.
    public func setEncoderBudget(active: Int, max: Int, ledger: [String]) {
        state.withLock { s in
            s.encoderLeaseCount = active
            s.encoderBudgetMax = max
            s.encoderLedger = ledger
        }
    }

    /// Phase 45: clears encoder budget diagnostics.
    public func clearEncoderBudget() {
        state.withLock { s in
            s.encoderLeaseCount = 0
            s.encoderBudgetMax = 0
            s.encoderLedger = []
        }
    }

    public func clearRenderSamples() {
        state.withLock { s in
            s.renderTimes.removeAll()
            s.lastRenderTime = 0
            s.totalFrameCount = 0
        }
    }
}
