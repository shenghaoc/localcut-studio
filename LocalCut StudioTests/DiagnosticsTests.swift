import Testing
import Foundation
import AVFoundation
@testable import LocalCut_Studio

@MainActor
@Suite("Diagnostics")
struct DiagnosticsTests {

    /// A control over the agent's wall-clock source so a single test can drive
    /// CPU calibration deterministically.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CFAbsoluteTime
        init(start: CFAbsoluteTime = 1_000) { self.value = start }
        func read() -> CFAbsoluteTime { lock.withLock { value } }
        func advance(by seconds: CFAbsoluteTime) { lock.withLock { value += seconds } }
    }

    // MARK: - V1 — probes resolve to non-NaN within 2 s

    @Test("Probes resolve to finite, non-NaN samples within 2 s of start()")
    func probesAreFiniteOnFirstTicks() async throws {
        DiagnosticsBridge.shared.reset()
        let agent = DiagnosticsAgent()
        agent.start()
        defer { agent.stop() }

        // The live timer fires once a second; two driven ticks simulate the
        // first 2 s of operation without paying for `Task.sleep(2)` in CI. The
        // first tick is the CPU calibration and the second is a real reading.
        agent.tickForTesting()
        agent.tickForTesting()

        #expect(agent.cpuUtilisation.isFinite)
        #expect(!agent.cpuUtilisation.isNaN)
        #expect(agent.gpuUtilisation.isFinite)
        #expect(!agent.gpuUtilisation.isNaN)
        #expect(agent.lastFrameTime.isFinite)
        #expect(!agent.lastFrameTime.isNaN)
        #expect(agent.p95RenderTime.isFinite)
        #expect(!agent.p95RenderTime.isNaN)
        #expect(agent.decoderCount >= 0)
        #expect(agent.frameDropsLastTick >= 0)
        #expect(agent.sampleCount == 2)
    }

    // MARK: - V2 — pause stops sampling

    @Test("Pausing the agent stops sampling — sampleCount stays put after stop()")
    func pausingStopsSampling() async throws {
        DiagnosticsBridge.shared.reset()
        let agent = DiagnosticsAgent()
        agent.start()
        agent.tickForTesting()
        let countWhileRunning = agent.sampleCount
        #expect(countWhileRunning == 1)

        agent.stop()
        #expect(!agent.isRunning)

        // After stop(), even a full second on the run loop should not produce
        // another sample because the timer was invalidated.
        try await Task.sleep(for: .seconds(1))
        #expect(agent.sampleCount == countWhileRunning)
    }

    // MARK: - V3 — render-time p95 reflects an injected slow frame

    @Test("Render-time p95 reflects an injected slow frame")
    func p95ReflectsInjectedSlowFrame() {
        DiagnosticsBridge.shared.reset()
        let agent = DiagnosticsAgent()
        agent.start()
        defer { agent.stop() }

        // Nearest-rank P95 across 20 samples lands on the 19th sorted entry
        // (ceil(0.95 · 20) = 19, i.e. sorted[18] 0-indexed). Two slow outliers
        // out of 20 push sorted[18] into the slow population — one outlier in 20
        // sits *above* the 95th percentile by definition, so the test injects
        // two to keep the assertion meaningful.
        for _ in 0..<18 { DiagnosticsBridge.shared.recordRenderTime(0.005) }  // 5 ms baseline
        DiagnosticsBridge.shared.recordRenderTime(0.250)                       // 250 ms outliers
        DiagnosticsBridge.shared.recordRenderTime(0.250)

        agent.tickForTesting()

        #expect(agent.p95RenderTime >= 0.25)
        // The last-frame metric reports the most recent sample, not the percentile.
        #expect(abs(agent.lastFrameTime - 0.250) < 1e-6)
    }

    // MARK: - V4 — render-time ring stays bounded

    @Test("Render-time ring stays bounded at the bridge's capacity")
    func ringIsBounded() {
        DiagnosticsBridge.shared.reset()
        let cap = DiagnosticsBridge.renderTimeCapacity
        for i in 0..<(cap * 4) {
            DiagnosticsBridge.shared.recordRenderTime(Double(i) / 1000)
        }
        let snapshot = DiagnosticsBridge.shared.snapshot()
        #expect(snapshot.renderTimes.count == cap)
        // The oldest samples got evicted; the youngest survive.
        #expect(snapshot.renderTimes.last == Double(cap * 4 - 1) / 1000)
    }

    // MARK: - CPU baseline behaviour

    @Test("CPU utilisation reads 0 on the calibration tick and is bounded 0…1 afterwards")
    func cpuCalibrationBehaviour() {
        DiagnosticsBridge.shared.reset()
        let clock = Clock(start: 1_000)
        let agent = DiagnosticsAgent(now: { clock.read() })
        agent.start()
        defer { agent.stop() }

        agent.tickForTesting()
        #expect(agent.cpuUtilisation == 0)  // calibration tick

        clock.advance(by: 1.0)
        agent.tickForTesting()
        #expect(agent.cpuUtilisation >= 0)
        #expect(agent.cpuUtilisation <= 1)
    }

    // MARK: - Frame-drop delta

    @Test("Dropped-frame metric reports the per-tick delta, not the cumulative count")
    func droppedFrameDelta() {
        DiagnosticsBridge.shared.reset()
        let drops = DropsCounter()
        let agent = DiagnosticsAgent(droppedFramesProvider: { drops.read() })
        agent.start()
        defer { agent.stop() }

        drops.set(5)
        agent.tickForTesting()
        #expect(agent.frameDropsLastTick == 5)

        drops.set(7)
        agent.tickForTesting()
        // Delta only: 7 - 5 = 2, not the cumulative 7.
        #expect(agent.frameDropsLastTick == 2)
    }

    private final class DropsCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func set(_ v: Int) { lock.withLock { value = v } }
        func read() -> Int { lock.withLock { value } }
    }

    // MARK: - Decoder count propagation

    @Test("Decoder count published to the bridge surfaces on the next tick")
    func decoderCountPropagates() {
        DiagnosticsBridge.shared.reset()
        let agent = DiagnosticsAgent()
        agent.start()
        defer { agent.stop() }

        DiagnosticsBridge.shared.setDecoderCount(4)
        agent.tickForTesting()
        #expect(agent.decoderCount == 4)
    }

    // MARK: - Start resets stale state

    @Test("start() clears stale samples from a previous panel session")
    func startResetsState() {
        // Seed the bridge as if a previous session had filled the ring.
        DiagnosticsBridge.shared.reset()
        for _ in 0..<10 { DiagnosticsBridge.shared.recordRenderTime(0.100) }

        let agent = DiagnosticsAgent()
        agent.start()
        defer { agent.stop() }
        agent.tickForTesting()

        // The bridge was reset by start(); the first post-start tick reads an
        // empty ring, so p95 is zero rather than reporting the stale 100 ms.
        #expect(agent.p95RenderTime == 0)
        #expect(agent.lastFrameTime == 0)
    }
}
