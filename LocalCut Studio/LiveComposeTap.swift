import Foundation
@preconcurrency import CoreVideo
import CoreMedia

// MARK: - LiveComposeTap

/// Per-source bridge from each capture pipeline's frame reader to the
/// `ProgramCompositor`. The tap retains the latest `CVPixelBuffer` wrapper
/// for compositing. Frames stay warm even for invisible sources so that a
/// scene switch revealing a slow-FPS source has a frame ready immediately.
///
/// The encode path and compose path retain references to the same
/// underlying `IOSurface`; no pixel copy is performed. The previous
/// wrapper is released only when a newer one arrives or the session is
/// disposed.
nonisolated final class LiveComposeTap: @unchecked Sendable {

    /// The source ID this tap is attached to.
    let sourceID: UUID

    /// Lock protecting all mutable state.
    private let lock = NSLock()

    /// The latest pixel buffer for compositing.
    private var _latestBuffer: CVPixelBuffer?
    private var _isDisposed = false

    var latestBuffer: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return _latestBuffer
    }

    var isDisposed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isDisposed
    }

    /// Callback invoked when the tap is disposed (once).
    private let onDispose: (@Sendable () -> Void)?

    nonisolated init(sourceID: UUID, onDispose: (@Sendable () -> Void)? = nil) {
        self.sourceID = sourceID
        self.onDispose = onDispose
    }

    /// Feeds a new frame to the tap. The previous buffer is released.
    func feed(_ buffer: CVPixelBuffer) {
        lock.lock()
        guard !_isDisposed else { lock.unlock(); return }
        _latestBuffer = buffer
        lock.unlock()
    }

    /// Disposes the tap, releasing the held buffer. Safe to call multiple
    /// times — only the first call triggers the `onDispose` callback.
    func dispose() {
        lock.lock()
        guard !_isDisposed else { lock.unlock(); return }
        _isDisposed = true
        _latestBuffer = nil
        lock.unlock()
        onDispose?()
    }

    deinit {
        // Ensure cleanup even if dispose() was never called explicitly.
        // Note: onDispose may not be called if the tap is dropped without
        // dispose() — this is acceptable since the session owns the lifecycle.
    }
}
