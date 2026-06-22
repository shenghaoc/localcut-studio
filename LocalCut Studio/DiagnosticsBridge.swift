import Foundation
import os

/// Thread-safe handoff between the AVFoundation render queue (where
/// `EffectCompositor.startRequest` runs) and the main-actor `DiagnosticsAgent`.
///
/// The compositor writes per-frame render times and the editor publishes the
/// composition's decoder count; the agent reads a coherent snapshot on its
/// once-per-second tick. All state is guarded by `OSAllocatedUnfairLock`, so the
/// bridge is `Sendable` and the cross-thread surface is two method calls.
final class DiagnosticsBridge: Sendable {

    nonisolated static let shared = DiagnosticsBridge()

    /// Max samples retained in the render-time ring. ~8.5 s of preview at 30 fps
    /// — long enough to smooth a single slow frame's effect on the percentile,
    /// short enough that a 30-second-old spike doesn't drag the metric.
    nonisolated static let renderTimeCapacity = 256

    struct Snapshot: Sendable {
        let renderTimes: [Double]
        let lastRenderTime: Double
        let decoderCount: Int
        /// Monotonic count of every render the compositor has recorded since
        /// the last `reset()` / `clearRenderSamples()`. The agent uses this to
        /// detect a quiet tick (no new frames since last sample) and report
        /// GPU = 0 instead of dragging a stale mean off the ring.
        let totalFrameCount: Int
    }

    private struct State {
        var renderTimes: [Double] = []
        var lastRenderTime: Double = 0
        var decoderCount: Int = 0
        var totalFrameCount: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Separate one-bit lock so the compositor can read the gate without
    /// contending on the data lock once per frame. Toggled by the agent's
    /// `start()` / `stop()` so the hot path skips the timestamp + record call
    /// entirely while the panel is hidden.
    private let enabledFlag = OSAllocatedUnfairLock(initialState: false)

    /// The hot-path gate. `EffectCompositor.startRequest` checks this *before*
    /// taking a timestamp, so a hidden panel pays nothing per frame beyond a
    /// single uncontended unfair-lock acquire.
    nonisolated var isEnabled: Bool {
        enabledFlag.withLock { $0 }
    }

    nonisolated func setEnabled(_ value: Bool) {
        enabledFlag.withLock { $0 = value }
    }

    /// Called by `EffectCompositor.startRequest` after a frame completes.
    /// The ring is bounded so a long-running session can't grow it unboundedly.
    /// Always records — the gate lives in the compositor so tests can inject
    /// samples directly without flipping `isEnabled`.
    nonisolated func recordRenderTime(_ seconds: Double) {
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

    /// Called by `EditorModel.rebuild()` after a successful `CompositionBuilder.build`.
    nonisolated func setDecoderCount(_ count: Int) {
        state.withLock { $0.decoderCount = count }
    }

    /// A coherent read of every published value at a single instant.
    nonisolated func snapshot() -> Snapshot {
        state.withLock { s in
            Snapshot(renderTimes: s.renderTimes,
                     lastRenderTime: s.lastRenderTime,
                     decoderCount: s.decoderCount,
                     totalFrameCount: s.totalFrameCount)
        }
    }

    /// Clears only the render-time ring + the monotonic frame counter — the
    /// inputs that should reset between panel sessions and when the timeline
    /// loses its composition. Decoder count and drop counter are owned by the
    /// editor / player and shouldn't be zeroed when the panel toggles.
    nonisolated func clearRenderSamples() {
        state.withLock { s in
            s.renderTimes.removeAll()
            s.lastRenderTime = 0
            s.totalFrameCount = 0
        }
    }

    /// Clears every collected sample. Tests call this between cases for a clean
    /// baseline; production code uses `clearRenderSamples()` instead.
    nonisolated func reset() {
        state.withLock { s in
            s.renderTimes.removeAll()
            s.lastRenderTime = 0
            s.decoderCount = 0
            s.totalFrameCount = 0
        }
        enabledFlag.withLock { $0 = false }
    }
}
