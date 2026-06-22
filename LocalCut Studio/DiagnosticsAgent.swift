import Foundation
import AVFoundation
import Observation
import os
import Darwin

/// Probes editor performance at 1 Hz and exposes the rolling samples to the
/// `DiagnosticsView`. Owned by `EditorModel`; only runs while the panel is
/// visible so a hidden panel costs nothing.
@Observable
@MainActor
final class DiagnosticsAgent {

    // MARK: - Published samples

    /// 0…1 across all logical cores. `1.0` means every core is saturated.
    private(set) var cpuUtilisation: Double = 0
    /// Best-effort estimate: `mean(renderTime) / frameDuration`, clamped 0…1,
    /// **and zeroed whenever no new frames arrived during the last tick**.
    /// Labelled "GPU (est.)" in the panel — macOS 26 has no entitlement-free
    /// counter API, so this proxies the compositor's share of frame budget
    /// (Core Image runs on Metal under the hood).
    private(set) var gpuUtilisation: Double = 0
    /// Video tracks in the most recent built composition; proxies the active
    /// VideoToolbox decoder count one-to-one for the playback pipeline.
    private(set) var decoderCount: Int = 0
    /// Most recent compositor render time, in seconds.
    private(set) var lastFrameTime: Double = 0
    /// 95th percentile render time over the bridge's 256-sample ring, in seconds.
    private(set) var p95RenderTime: Double = 0
    /// Frame drops in the last tick (delta against the player's monotonic counter).
    private(set) var frameDropsLastTick: Int = 0
    /// Whether the agent's timer is currently scheduled.
    private(set) var isRunning = false
    /// Bumped on every successful sample tick; lets tests verify pause behaviour.
    private(set) var sampleCount: Int = 0
    /// The last ≤ 60 render-time samples in milliseconds, for the sparkline.
    private(set) var sparkline: [Double] = []

    // MARK: - Wiring

    /// Wall-clock source — overridable so tests can synthesise a known delta.
    @ObservationIgnored private let now: @Sendable () -> CFAbsoluteTime
    /// Frame-duration provider — defaults to 30 fps when the editor has no
    /// project yet; the live agent wires it to `project.frameRate`.
    @ObservationIgnored private let frameDuration: @MainActor () -> Double
    /// Source of cumulative dropped-frame count. Real wiring reads
    /// `AVPlayerItem.accessLog().events.last?.numberOfDroppedVideoFrames`; tests
    /// can substitute a fixed function.
    @ObservationIgnored private let droppedFramesProvider: @MainActor () -> Int

    @ObservationIgnored private let log = Logger(
        subsystem: "com.localcutstudio.diagnostics",
        category: "sample")

    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?

    /// CPU calibration baseline. `nil` until the first tick after `start()`.
    @ObservationIgnored private var previousCPUSeconds: Double?
    @ObservationIgnored private var previousWallClock: CFAbsoluteTime?
    @ObservationIgnored private var previousDroppedFrames: Int = 0
    /// Snapshot of the bridge's monotonic frame counter at the last tick. The
    /// delta tells us whether new frames arrived this tick, which gates the
    /// GPU-utilisation estimate so a paused player reads 0 instead of dragging
    /// the historical mean off the ring.
    @ObservationIgnored private var previousTotalFrameCount: Int = 0

    /// Visible window into the sparkline — sized so a 1080p panel can plot it
    /// readably without overrun.
    nonisolated private static let sparklineCapacity = 60

    init(
        now: @escaping @Sendable () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() },
        frameDuration: @escaping @MainActor () -> Double = { 1.0 / 30.0 },
        droppedFramesProvider: @escaping @MainActor () -> Int = { 0 }
    ) {
        self.now = now
        self.frameDuration = frameDuration
        self.droppedFramesProvider = droppedFramesProvider
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Schedules the 1 Hz timer and resets calibration. Idempotent — calling
    /// `start()` on an already-running agent is a no-op.
    func start() {
        guard !isRunning else { return }
        // Clear render-related state only — the bridge's decoder count was
        // published by the most recent `EditorModel.rebuild()` and the panel
        // visibility toggle does *not* schedule a rebuild, so wiping it would
        // leave the Decoders row stuck at 0 until the next edit (Codex P1).
        DiagnosticsBridge.shared.clearRenderSamples()
        DiagnosticsBridge.shared.setEnabled(true)
        previousCPUSeconds = nil
        previousWallClock = nil
        // Seed the drop baseline from the live cumulative count so the first
        // tick reports drops that happened during *this* session, not historical
        // drops accumulated before the panel was opened (Codex P2 / Gemini).
        previousDroppedFrames = droppedFramesProvider()
        previousTotalFrameCount = 0
        sampleCount = 0
        cpuUtilisation = 0
        gpuUtilisation = 0
        lastFrameTime = 0
        p95RenderTime = 0
        frameDropsLastTick = 0
        sparkline = []
        isRunning = true

        // Tolerance lets the system batch the timer with other 1 Hz wakeups so a
        // hidden-but-foreground app pays no extra wakeup overhead. The timer
        // runs on the main run loop because the agent is `@MainActor`.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Invalidates the timer so probes stop sampling. Safe to call multiple times.
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        // Close the hot-path gate so the compositor stops paying for the
        // timestamp + record call on every preview / export frame.
        DiagnosticsBridge.shared.setEnabled(false)
    }

    /// Drives one sample synchronously. Tests call this instead of waiting on the
    /// timer; production code goes through the timer's `tick()`.
    func tickForTesting() {
        tick()
    }

    // MARK: - Tick

    private func tick() {
        let bridge = DiagnosticsBridge.shared.snapshot()
        let wallNow = now()

        // Dropped frames: pull from the player, publish the cumulative count to
        // the bridge so the snapshot reads a coherent value, then report the
        // per-tick delta.
        let cumulativeDrops = droppedFramesProvider()
        DiagnosticsBridge.shared.setDroppedFrames(cumulativeDrops)
        let delta = max(0, cumulativeDrops - previousDroppedFrames)
        previousDroppedFrames = cumulativeDrops
        frameDropsLastTick = delta

        // CPU: task_info delta over wall-clock delta, normalised by core count.
        cpuUtilisation = sampleCPU(now: wallNow)

        // Render time: percentile over the ring, last sample, sparkline window.
        let times = bridge.renderTimes
        lastFrameTime = bridge.lastRenderTime.isFinite ? bridge.lastRenderTime : 0
        p95RenderTime = percentile(times, p: 0.95)
        sparkline = Array(times.suffix(Self.sparklineCapacity).map { $0 * 1000 })

        // GPU (est.): how much of the per-frame budget the compositor used on
        // average. Zeroed when no new frames arrived this tick so the metric
        // doesn't drag the historical mean off the ring while the player is
        // paused (Gemini medium #2).
        let framesThisTick = bridge.totalFrameCount - previousTotalFrameCount
        previousTotalFrameCount = bridge.totalFrameCount
        let frame = frameDuration()
        if framesThisTick > 0, !times.isEmpty, frame > 0 {
            let mean = times.reduce(0, +) / Double(times.count)
            gpuUtilisation = max(0, min(1, mean / frame))
        } else {
            gpuUtilisation = 0
        }

        decoderCount = bridge.decoderCount
        sampleCount += 1

        log.info("""
            sample cpu=\(self.cpuUtilisation, format: .fixed(precision: 3), privacy: .public) \
            gpu_est=\(self.gpuUtilisation, format: .fixed(precision: 3), privacy: .public) \
            decoders=\(self.decoderCount, privacy: .public) \
            last_ms=\(self.lastFrameTime * 1000, format: .fixed(precision: 2), privacy: .public) \
            p95_ms=\(self.p95RenderTime * 1000, format: .fixed(precision: 2), privacy: .public) \
            drops=\(self.frameDropsLastTick, privacy: .public)
            """)
    }

    // MARK: - Probes

    /// Total live + terminated thread CPU time, in seconds. `nil` if the
    /// `proc_pidinfo` call fails.
    ///
    /// We deliberately go through libproc rather than `task_info` here. The
    /// Mach interface splits the same number across two flavors —
    /// `TASK_THREAD_TIMES_INFO` for live threads and `MACH_TASK_BASIC_INFO`
    /// for the time terminated threads contributed on exit — which means
    /// querying only one half undercounts whichever side the workload happens
    /// to land on (Gemini high). On macOS 26 the SDK also marks
    /// `MACH_TASK_BASIC_INFO_COUNT` unavailable, so the two-step Mach query
    /// won't compile. `proc_pidinfo(PROC_PIDTASKINFO)` returns
    /// `pti_total_user` + `pti_total_system` in nanoseconds covering both
    /// live and terminated threads in one call, works on the own-process pid
    /// without entitlements, and avoids the deprecated Mach surface entirely.
    nonisolated private func currentCPUSeconds() -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return nil }
        let user = Double(info.pti_total_user) / 1_000_000_000
        let system = Double(info.pti_total_system) / 1_000_000_000
        return user + system
    }

    private func sampleCPU(now wallNow: CFAbsoluteTime) -> Double {
        guard let nowSec = currentCPUSeconds() else {
            previousCPUSeconds = nil
            previousWallClock = nil
            return 0
        }
        defer {
            previousCPUSeconds = nowSec
            previousWallClock = wallNow
        }
        guard let prevCPU = previousCPUSeconds, let prevWall = previousWallClock else {
            return 0  // calibration tick
        }
        let wallDelta = wallNow - prevWall
        guard wallDelta > 0 else { return cpuUtilisation }
        let cpuDelta = nowSec - prevCPU
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let utilisation = cpuDelta / wallDelta / Double(cores)
        return max(0, min(1, utilisation))
    }

    /// O(n log n) percentile over a copy. n ≤ 256, so this is fine on every tick
    /// — picking a percentile estimator like P² would save the sort but trade
    /// determinism (a slow frame would slowly drift the estimator's value rather
    /// than reflecting in the next tick, which is exactly the assertion the V3
    /// regression test relies on).
    nonisolated private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        // Standard nearest-rank: ceil(p · n).
        let index = max(0, min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[index]
    }
}
