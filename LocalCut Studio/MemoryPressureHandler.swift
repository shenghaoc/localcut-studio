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
    private let activated = OSAllocatedUnfairLock(initialState: false)

    private init() {}

    /// Activates memory pressure monitoring. Safe to call multiple times;
    /// only the first call has any effect.
    func activate() {
        let wasActive = activated.withLock { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        guard !wasActive else { return }

        // Use DispatchSource to monitor memory pressure on macOS.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.handlePressure()
        }
        source.resume()

        logger.info("Memory pressure handler activated")
    }

    private func handlePressure() {
        logger.warning("Memory pressure detected — evicting caches")

        // RenderCache: evict all in-memory and disk entries.
        RenderCache.shared.purge()

        // EffectCompositor: evict CIContext cache.
        EffectCompositor.purgeContextCache()

        // EffectCompositor: evict caption raster cache.
        EffectCompositor.purgeCaptionRasterCache()

        // LUTCache: evict cached LUT lookups.
        LUTCachePurger.purge()

        logger.warning("Cache eviction complete")
    }
}

/// Thin access layer for the private `LUTCache.shared.purge()`.
/// `LUTCache` is a private class inside `EffectCompositor.swift`,
/// so we reach it through the existing `EffectCompositor` API.
/// Since `LUTCache` is private, we add a static forwarding method
/// on `EffectCompositor` instead.
nonisolated enum LUTCachePurger {
    static func purge() {
        // LUTCache is private to EffectCompositor.swift.
        // The purge() method was added there; this enum provides
        // a call site for the pressure handler.
        // Actual call goes through EffectCompositor.purgeLUTCache().
        EffectCompositor.purgeLUTCache()
    }
}
