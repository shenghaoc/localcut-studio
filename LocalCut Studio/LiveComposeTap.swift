import Foundation
import CoreVideo
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
final class LiveComposeTap: @unchecked Sendable {

    /// The source ID this tap is attached to.
    let sourceID: UUID

    /// The latest pixel buffer for compositing. Thread-safe via lock.
    private var _latestBuffer: CVPixelBuffer?
    private var _isDisposed = false
    private let lock = NSLock()

    /// Callback invoked when the tap is disposed (once). Useful for
    /// cleanup coordination.
    private let onDispose: (@Sendable () -> Void)?

    init(sourceID: UUID, onDispose: (@Sendable () -> Void)? = nil) {
        self.sourceID = sourceID
        self.onDispose = onDispose
    }

    /// The latest pixel buffer, or nil if no frame has arrived yet.
    /// Thread-safe.
    var latestBuffer: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return _latestBuffer
    }

    /// Whether this tap has been disposed.
    var isDisposed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isDisposed
    }

    /// Feeds a new frame to the tap. The previous buffer is released.
    /// This is the zero-copy path: the caller wraps the IOSurface-backed
    /// `CVPixelBuffer` without copying pixels. The tap retains only the
    /// wrapper; the underlying IOSurface is shared with the encode path.
    ///
    /// Calling `feed` after `dispose` is a no-op.
    func feed(_ buffer: CVPixelBuffer) {
        lock.lock()
        guard !_isDisposed else {
            lock.unlock()
            return
        }
        _latestBuffer = buffer
        lock.unlock()
    }

    /// Disposes the tap, releasing the held buffer. Safe to call multiple
    /// times — only the first call triggers the `onDispose` callback.
    func dispose() {
        lock.lock()
        guard !_isDisposed else {
            lock.unlock()
            return
        }
        _isDisposed = true
        _latestBuffer = nil
        lock.unlock()
        onDispose?()
    }

    deinit {
        // Ensure cleanup even if dispose() was never called explicitly.
        lock.lock()
        let wasDisposed = _isDisposed
        lock.unlock()
        if !wasDisposed {
            onDispose?()
        }
    }
}
