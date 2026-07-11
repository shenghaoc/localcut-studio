import Foundation
import CoreImage
import CoreGraphics
import CoreMedia
import LocalCutCore

// MARK: - Frame source protocol

/// Provides decoded CIImage frames for an animated overlay source at arbitrary
/// timeline times. Implementations must be thread-safe — the compositor awaits
/// `frame(at:)` from AVFoundation render tasks that are not main-actor bound.
public protocol OverlayFrameSource: AnyObject, Sendable {
    /// The natural size (pixels) of the overlay source.
    nonisolated var naturalSize: CGSize { get }
    /// Number of decoded frames currently retained by the source cache.
    nonisolated var cachedFrameCount: Int { get }
    /// Returns the frame for the given overlay-local time (relative to the
    /// overlay clip's start). Returns nil if the time is out of range and the
    /// end action is `.hide`.
    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) async -> CIImage?
    /// Drops decoded frame caches while keeping the source usable for future
    /// requests.
    nonisolated func purgeCachedFrames()
}

public extension OverlayFrameSource {
    nonisolated var cachedFrameCount: Int { 0 }
    nonisolated func purgeCachedFrames() {}
}

// MARK: - Factory

public enum OverlayFrameSourceFactory: Sendable {
    /// Creates the appropriate frame source for the given overlay clip.
    /// The `sourceURL` is resolved from the bookmark or bundle-relative path.
    public static func makeSource(for overlay: OverlayClip,
                                  sourceURL: URL) async -> (any OverlayFrameSource)? {
        switch overlay.sourceType {
        case .animatedImage:
            return await Task.detached(priority: .userInitiated) {
                AnimatedImageSource(url: sourceURL)
            }.value
        case .lottie:
            return await LottieFrameSource.make(url: sourceURL)
        case .alphaVideo:
            return await AlphaVideoSource.make(url: sourceURL)
        }
    }
}
