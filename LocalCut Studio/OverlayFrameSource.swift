import Foundation
import CoreImage
import CoreGraphics
import CoreMedia
import LocalCutCore

// MARK: - Frame source protocol

/// Provides decoded CIImage frames for an animated overlay source at arbitrary
/// timeline times. Implementations must be thread-safe — the compositor calls
/// `frame(at:)` on its rendering thread.
protocol OverlayFrameSource: AnyObject, Sendable {
    /// The natural size (pixels) of the overlay source.
    nonisolated var naturalSize: CGSize { get }
    /// Returns the frame for the given overlay-local time (relative to the
    /// overlay clip's start). Returns nil if the time is out of range and the
    /// end action is `.hide`.
    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) -> CIImage?
}

// MARK: - Factory

enum OverlayFrameSourceFactory {
    /// Creates the appropriate frame source for the given overlay clip.
    /// The `sourceURL` is resolved from the bookmark or bundle-relative path.
    @MainActor
    static func makeSource(for overlay: OverlayClip,
                           sourceURL: URL) -> (any OverlayFrameSource)? {
        switch overlay.sourceType {
        case .animatedImage:
            return AnimatedImageSource(url: sourceURL)
        case .lottie:
            // Lottie support requires lottie-ios SPM dependency.
            // Return nil until the dependency is added.
            return nil
        case .alphaVideo:
            return AlphaVideoSource(url: sourceURL)
        }
    }
}
