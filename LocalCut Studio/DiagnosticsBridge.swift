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
        let droppedFrames: Int
    }

    private struct State {
        var renderTimes: [Double] = []
        var lastRenderTime: Double = 0
        var decoderCount: Int = 0
        var droppedFrames: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called by `EffectCompositor.startRequest` after a frame completes.
    /// The ring is bounded so a long-running session can't grow it unboundedly.
    nonisolated func recordRenderTime(_ seconds: Double) {
        state.withLock { s in
            s.renderTimes.append(seconds)
            s.lastRenderTime = seconds
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

    /// Latest cumulative dropped-frame count read from the player's access log;
    /// the agent computes the per-tick delta itself.
    nonisolated func setDroppedFrames(_ count: Int) {
        state.withLock { $0.droppedFrames = count }
    }

    /// A coherent read of every published value at a single instant.
    nonisolated func snapshot() -> Snapshot {
        state.withLock { s in
            Snapshot(renderTimes: s.renderTimes,
                     lastRenderTime: s.lastRenderTime,
                     decoderCount: s.decoderCount,
                     droppedFrames: s.droppedFrames)
        }
    }

    /// Clears every collected sample. Tests call this between cases; production
    /// code calls it from `DiagnosticsAgent.start()` so a fresh panel session
    /// doesn't show stale samples from a previous one.
    nonisolated func reset() {
        state.withLock { s in
            s.renderTimes.removeAll()
            s.lastRenderTime = 0
            s.decoderCount = 0
            s.droppedFrames = 0
        }
    }
}
