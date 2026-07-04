import Foundation
import os

/// Listens for system memory pressure notifications and coordinates
/// cache eviction across all singletons to prevent "out of application
/// memory" warnings.
///
/// Install once at app launch via `MemoryPressureHandler.shared.activate()`.
nonisolated final class MemoryPressureHandler: Sendable {

    nonisolated static let shared = MemoryPressureHandler()

    private let logger = Logger(subsystem: "com.localcut.studio", category: "MemoryPressure")
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    private init() {}

    /// Activates memory pressure monitoring. Safe to call multiple times;
    /// only the first call has any effect.
    func activate() {
        let source = state.withLock { state -> DispatchSourceMemoryPressure? in
            guard state.source == nil else { return nil }
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .global(qos: .utility)
            )
            state.source = source
            return source
        }
        guard let source else { return }
        source.setEventHandler { [weak self] in
            self?.handlePressure()
        }
        source.resume()

        logger.info("Memory pressure handler activated")
    }

    var isActive: Bool {
        state.withLock { $0.source != nil }
    }

    private func handlePressure() {
        purgeCachesForMemoryPressure()
    }

    func purgeCachesForMemoryPressure() {
        logger.warning("Memory pressure detected - evicting caches")

        // RenderCache: evict all in-memory and disk entries.
        RenderCache.shared.purge()

        // EffectCompositor: evict CIContext cache.
        EffectCompositor.purgeContextCache()

        // EffectCompositor: evict caption raster cache.
        EffectCompositor.purgeCaptionRasterCache()

        // Overlay frame sources: keep active registries but drop decoded frames.
        EffectCompositor.purgeOverlaySourceCaches()

        // LUTCache: evict cached LUT lookups.
        EffectCompositor.purgeLUTCache()

        logger.warning("Cache eviction complete")
    }

    private struct State {
        var source: DispatchSourceMemoryPressure?
    }
}
