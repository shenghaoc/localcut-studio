import Foundation
import AVFoundation
import CoreVideo

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
///
/// The whole namespace is `nonisolated` because nothing here touches the
/// main-actor model — composition rebuilds and the `Coordinator` actor both
/// need to call these statics across isolation domains.
nonisolated enum CaptionTailFiller {

    /// Default length of a freshly-generated filler. Most caption tails are a
    /// few seconds; this stays comfortably above that without bloating the
    /// cache directory.
    static let defaultGeneratedSeconds: Double = 30

    enum FillerError: Error {
        case cachesDirectoryUnavailable
        case writerStartFailed
        case writerFinishFailed
    }

    /// Returns a cached `AVURLAsset` whose duration is at least
    /// `minimumDuration`. Regenerates the file when the cached version is
    /// missing or too short. Concurrent callers for the same cache key share a
    /// single generation task so parallel composition rebuilds (rapid undo /
    /// redo in the app, or parallel tests against the same render size) cannot
    /// race on the writer output path.
    static func asset(renderSize: CGSize,
                      frameRate: Double,
                      minimumDuration: CMTime) async throws -> AVURLAsset {
        let url = try cacheURL(renderSize: renderSize, frameRate: frameRate)
        let needed = max(minimumDuration.seconds, 0)
        return try await Coordinator.shared.asset(
            at: url, needed: needed,
            renderSize: renderSize, frameRate: frameRate)
    }

    /// Serialises concurrent requests for the same cache URL. Without it, two
    /// parallel rebuilds for the same (size, fps) both see the file missing,
    /// both kick off an `AVAssetWriter` against the same path, and one writer
    /// fails or corrupts the output mid-stream. The shared task hands back the
    /// URL (not the asset) so the caller wraps a fresh `AVURLAsset` and we sidestep
    /// any cross-actor `Sendable` concerns about caching an AV object.
    private actor Coordinator {
        static let shared = Coordinator()
        private var inFlight: [URL: Task<URL, Error>] = [:]

        func asset(at url: URL, needed: Double,
                   renderSize: CGSize, frameRate: Double) async throws -> AVURLAsset {
            // Wait for any in-flight generation to finish, then evaluate the
            // cache against *our* `needed`. The disk check + regenerate is
            // owned by the in-flight task itself — moving it inside the task
            // is what keeps the slot-claim atomic. Without that, two callers
            // could each suspend on the disk's `load(.duration)`, then both
            // create their own `AVAssetWriter` against the same path.
            // (gemini-code-assist review #1).
            while let existing = inFlight[url] {
                _ = try? await existing.value
            }
            let task = Task<URL, Error> {
                try await Self.resolve(at: url, needed: needed,
                                       renderSize: renderSize, frameRate: frameRate)
            }
            inFlight[url] = task
            defer { inFlight[url] = nil }
            let ready = try await task.value
            return AVURLAsset(url: ready)
        }

        /// Decides whether the cached file already satisfies `needed`, and
        /// regenerates only when it doesn't. Runs inside the in-flight task
        /// so the entire decision is serialised per URL.
        private static func resolve(at url: URL, needed: Double,
                                     renderSize: CGSize, frameRate: Double) async throws -> URL {
            if FileManager.default.fileExists(atPath: url.path) {
                let cached = AVURLAsset(url: url)
                let cachedDuration = (try? await cached.load(.duration)) ?? .zero
                if cachedDuration.seconds + 1e-3 >= needed {
                    return url
                }
                try? FileManager.default.removeItem(at: url)
            }
            let generatedSeconds = max(defaultGeneratedSeconds, needed + 1)
            try await generate(at: url,
                               renderSize: renderSize,
                               frameRate: frameRate,
                               seconds: generatedSeconds)
            return url
        }
    }

    // MARK: - Internals

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
        let w = Int(renderSize.width.rounded())
        let h = Int(renderSize.height.rounded())
        let fps = Int(frameRate.rounded())
        return dir.appendingPathComponent("filler-\(w)x\(h)-\(fps)fps.mov")
    }

    private static func generate(at url: URL,
                                  renderSize: CGSize,
                                  frameRate: Double,
                                  seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)

        // H.264 (and most hardware video encoders) require even dimensions;
        // mask the low bit off after rounding rather than fail later inside
        // the writer (gemini-code-assist review #2).
        let width = max(2, Int(renderSize.width.rounded()) & ~1)
        let height = max(2, Int(renderSize.height.rounded()) & ~1)
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
            // Spin until the input can accept more data, but bail out if the
            // writer transitions out of `.writing` — otherwise a writer
            // failure mid-loop would hang this task forever
            // (gemini-code-assist review #3).
            while !videoInput.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                await Task.yield()
            }
            guard writer.status == .writing,
                  let pool = adaptor.pixelBufferPool else { break }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                // H.264 drops the alpha channel, so all-zero bytes are
                // sufficient to encode an opaque black frame.
                memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(value: CMTimeValue(frame), timescale: fpsTimescale)
            adaptor.append(buffer, withPresentationTime: pts)
        }
        videoInput.markAsFinished()

        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? FillerError.writerFinishFailed
        }
    }
}
