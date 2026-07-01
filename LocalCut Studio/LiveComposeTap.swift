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
@MainActor
final class LiveComposeTap {

    /// The source ID this tap is attached to.
    let sourceID: UUID

    /// The latest pixel buffer for compositing.
    private(set) var latestBuffer: CVPixelBuffer?

    /// Whether this tap has been disposed.
    private(set) var isDisposed = false

    /// Callback invoked when the tap is disposed (once).
    private let onDispose: (@Sendable () -> Void)?

    nonisolated init(sourceID: UUID, onDispose: (@Sendable () -> Void)? = nil) {
        self.sourceID = sourceID
        self.onDispose = onDispose
    }

    /// Feeds a new frame to the tap. The previous buffer is released.
    func feed(_ buffer: CVPixelBuffer) {
        guard !isDisposed else { return }
        latestBuffer = buffer
    }

    /// Disposes the tap, releasing the held buffer. Safe to call multiple
    /// times — only the first call triggers the `onDispose` callback.
    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        latestBuffer = nil
        onDispose?()
    }

    deinit {
        // Ensure cleanup even if dispose() was never called explicitly.
        // Note: onDispose may not be called if the tap is dropped without
        // dispose() — this is acceptable since the session owns the lifecycle.
    }
}
