import Foundation
import os
@preconcurrency import CoreVideo
import CoreMedia

// MARK: - LiveComposeTap

/// Per-source bridge from each capture pipeline's frame reader to the
/// `ProgramCompositor`. The compositor owns the latest `CVPixelBuffer` cache;
/// the tap gates frame delivery after disposal so closed sources cannot feed
/// new frames.
///
/// The encode path and compose path retain references to the same
/// underlying `IOSurface`; no pixel copy is performed.
nonisolated final class LiveComposeTap: @unchecked Sendable {

    /// The source ID this tap is attached to.
    let sourceID: UUID

    /// Lock protecting all mutable state.
    private let lock = OSAllocatedUnfairLock(initialState: ())

    private var _isDisposed = false

    var isDisposed: Bool {
        lock.withLock { _ in _isDisposed }
    }

    /// Callback invoked when the tap is disposed (once).
    private let onDispose: (@Sendable () -> Void)?

    nonisolated init(sourceID: UUID, onDispose: (@Sendable () -> Void)? = nil) {
        self.sourceID = sourceID
        self.onDispose = onDispose
    }

    /// Returns the frame when the tap is still active; nil after disposal.
    func feed(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        lock.withLockUnchecked { _ -> CVPixelBuffer? in
            guard !_isDisposed else { return nil }
            return buffer
        }
    }

    /// Disposes the tap. Safe to call multiple times — only the first call
    /// triggers the `onDispose` callback.
    func dispose() {
        let isFirstDispose = lock.withLock { _ -> Bool in
            guard !_isDisposed else { return false }
            _isDisposed = true
            return true
        }
        if isFirstDispose { onDispose?() }
    }

    deinit {
        // Ensure cleanup even if dispose() was never called explicitly.
        // Note: onDispose may not be called if the tap is dropped without
        // dispose() — this is acceptable since the session owns the lifecycle.
    }
}
