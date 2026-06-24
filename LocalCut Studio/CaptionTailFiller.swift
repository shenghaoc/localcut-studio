import Foundation
import AVFoundation
import CoreVideo
import LocalCutCore

/// Generates and caches a tiny black-frame `.mov` used to extend an
/// `AVMutableComposition` when a caption ends past the last AV clip. The
/// composition only needs a real source track in that tail interval to push
/// `composition.duration` forward — `EffectCompositor` then composites the
/// caption over a black background for the tail just as it would over any
/// other gap, and export sees a well-formed video track that runs to the
/// caption's true end.
///
/// `AVMutableComposition.insertEmptyTimeRange` was tried first but did not
/// reliably update `composition.duration` in the parallel test suite on
/// macOS 26; inserting a real placeholder asset does.
///
/// Cached under `~/Library/Caches/<bundleID>/CaptionTailFillers/`, keyed by
/// (renderSize, frameRate) so a project resize regenerates rather than
/// stretching a wrong-sized asset through the compositor's transforms.
nonisolated enum CaptionTailFiller {

    /// Default length of a freshly-generated filler. Most caption tails are a
    /// few seconds; keeping the default small keeps cold-start generation
    /// fast (writing 60+ s of H.264 in a Debug build on a slow CI runner
    /// could otherwise dwarf the rest of a test).
    static let defaultGeneratedSeconds: Double = 5

    enum FillerError: Error {
        case cachesDirectoryUnavailable
        case writerStartFailed
        case writerFinishFailed
    }

    /// Returns a cached `AVURLAsset` whose duration is at least
    /// `minimumDuration`. Regenerates the file when the cached version is
    /// missing or too short.
    ///
    /// Concurrent callers requesting the same key are isolated by writing
    /// to a unique per-call temp path and then atomically replacing the
    /// cached file. If two rebuilds race (e.g. an export overlapping a
    /// preview rebuild), the last-rename-wins; neither caller ever sees a
    /// half-written file underneath them. Two cold-start callers may both
    /// generate the full filler — the trade-off (redundant work vs.
    /// coordinator complexity) is acceptable for a ~5 s encode.
    static func asset(renderSize: CGSize,
                      frameRate: Double,
                      minimumDuration: CMTime) async throws -> AVURLAsset {
        let url = try cacheURL(renderSize: renderSize, frameRate: frameRate)
        let needed = minimumDuration.sanitized.seconds

        if FileManager.default.fileExists(atPath: url.path) {
            let cached = AVURLAsset(url: url)
            let cachedDuration = ((try? await cached.load(.duration)) ?? .zero).sanitized
            if isCachedDurationUsable(cachedDuration, neededSeconds: needed) {
                return cached
            }
        }

        let generatedSeconds = max(defaultGeneratedSeconds, needed + 1)
        try await generateAtomically(finalURL: url,
                                     renderSize: renderSize,
                                     frameRate: frameRate,
                                     seconds: generatedSeconds)
        return AVURLAsset(url: url)
    }

    /// Writes to a unique temp file in the same directory, then replaces the
    /// cached file in one rename. Same-directory write lets `replaceItem` use
    /// a true rename (no copy across filesystems) and means a concurrent
    /// reader either sees the old file or the new file — never a partial
    /// write under a stable name.
    private static func generateAtomically(finalURL: URL,
                                            renderSize: CGSize,
                                            frameRate: Double,
                                            seconds: Double) async throws {
        let directory = finalURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(
            ".\(UUID().uuidString).partial.mov")

        do {
            try await generate(at: tempURL,
                               renderSize: renderSize,
                               frameRate: frameRate,
                               seconds: seconds)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            do {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
                return
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }
        // Destination doesn't exist yet — straight rename.
        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            // Another writer may have just put a file in place; if it's now
            // present, fall through with their version rather than fail.
            if !FileManager.default.fileExists(atPath: finalURL.path) {
                throw error
            }
        }
    }

    // MARK: - Internals

    static func isCachedDurationUsable(_ cachedDuration: CMTime, neededSeconds: Double) -> Bool {
        cachedDuration > .zero && cachedDuration.seconds + 1e-3 >= neededSeconds
    }

    private static func cacheURL(renderSize: CGSize, frameRate: Double) throws -> URL {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else {
            throw FillerError.cachesDirectoryUnavailable
        }
        let bundle = Bundle.main.bundleIdentifier ?? "LocalCutStudio"
        let dir = caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("CaptionTailFillers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        // Cache key must match what `generate` actually writes so a render
        // size of e.g. 319×180 doesn't yield a filename that disagrees with
        // the file's even-clamped frame size.
        let (w, h) = evenDimensions(renderSize)
        let fps = Int(frameRate.rounded())
        return dir.appendingPathComponent("filler-\(w)x\(h)-\(fps)fps.mov")
    }

    /// Even-rounded width × height suitable for H.264. Both call sites
    /// (`cacheURL` and `generate`) must agree.
    private static func evenDimensions(_ size: CGSize) -> (Int, Int) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return (2, 2)
        }
        return (max(2, Int(size.width.rounded())  & ~1),
                max(2, Int(size.height.rounded()) & ~1))
    }

    private static func generate(at url: URL,
                                  renderSize: CGSize,
                                  frameRate: Double,
                                  seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)

        // H.264 (and most hardware video encoders) require even dimensions;
        // mask the low bit off after rounding rather than fail later inside
        // the writer.
        let (width, height) = evenDimensions(renderSize)
        let fps = max(1.0, frameRate)
        let fpsTimescale = CMTimeScale(max(1, Int(fps.rounded())))
        let frameCount = max(1, Int((seconds * fps).rounded()))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw writer.error ?? FillerError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            // Allow rapid undo/redo to tear down a half-written filler quickly.
            try Task.checkCancellation()
            // Spin until the input can accept more data, but bail out if the
            // writer transitions out of `.writing` — otherwise a writer
            // failure mid-loop would hang this task forever.
            while !videoInput.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                await Task.yield()
            }
            guard writer.status == .writing else { break }
            guard let pool = adaptor.pixelBufferPool else {
                throw FillerError.writerStartFailed
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw FillerError.writerStartFailed
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                // H.264 drops the alpha channel, so all-zero bytes are
                // sufficient to encode an opaque black frame.
                memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(value: CMTimeValue(frame), timescale: fpsTimescale)
            // Surface a dropped append immediately so a partial encode
            // doesn't hide behind the post-loop `.completed` check.
            guard adaptor.append(buffer, withPresentationTime: pts) else { break }
        }
        videoInput.markAsFinished()

        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? FillerError.writerFinishFailed
        }
    }
}
