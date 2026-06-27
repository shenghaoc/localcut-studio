import Testing
import Foundation
import AVFoundation
import CoreImage
import LocalCutCore
@testable import LocalCut_Studio

/// Preview composition smoke tests plus the observable player-item state
/// regression that keeps the SwiftUI preview canvas in sync with rebuilds.
@MainActor
@Suite("Preview composition and state")
struct PreviewVideoDiagnosticsTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Fixture

    private func makeVideoFixture(seconds: Double, fps: Int32 = 30,
                                  size: CGSize = CGSize(width: 64, height: 64)) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-video-fixture-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * Double(fps))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func loadedMedia(from url: URL) async throws -> MediaItem {
        let item = MediaItem(url: url)
        item.duration = try await item.asset.load(.duration)
        let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
        let track = try #require(videoTracks.first)
        item.hasVideo = true
        item.naturalSize = try await track.load(.naturalSize)
        item.preferredTransform = try await track.load(.preferredTransform)
        return item
    }

    // MARK: - Tests

    @Test("Video composition is built and has correct structure")
    func videoCompositionStructure() async throws {
        let url = try await makeVideoFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let project = Project()
        let media = try await loadedMedia(from: url)
        project.mediaItems.append(media)

        let track = project.videoTracks.first!
        let clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: time(1), timelineStart: .zero)
        track.clips = [clip]

        let built = try #require(try await CompositionBuilder.build(project: project))
        let videoComp = try #require(built.videoComposition,
                                     "videoComposition must not be nil for a project with a video clip")

        #expect(!videoComp.instructions.isEmpty, "videoComposition must have at least one instruction")
        #expect(videoComp.instructions.first?.timeRange.start == .zero)

        let videoTrackIDs = built.composition.tracks(withMediaType: .video).map(\.trackID)
        #expect(!videoTrackIDs.isEmpty, "Composition must have at least one video track")

        let customInstructions = videoComp.instructions.compactMap {
            $0 as? EffectCompositionInstruction
        }
        #expect(!customInstructions.isEmpty, "Instructions must be EffectCompositionInstruction instances")
        let simpleClipInstruction = try #require(customInstructions.first {
            !$0.units.isEmpty && $0.captions.isEmpty
        })
        #expect(simpleClipInstruction.containsTweening == false,
                "A plain clip interval should not force tweening")
        #expect(videoComp.renderSize.width > 0 && videoComp.renderSize.height > 0,
                "videoComposition.renderSize must be non-zero")
        #expect(videoComp.frameDuration.seconds > 0,
                "videoComposition.frameDuration must be non-zero")

        // Every instruction covering a visible clip interval must require source tracks.
        for instruction in customInstructions {
            let ids = instruction.requiredSourceTrackIDs?.compactMap {
                ($0 as? NSNumber)?.int32Value
            } ?? []
            if !instruction.units.isEmpty {
                // Intervals with units (visible clips) must reference the tracks.
                let overlappingIDs = ids.filter { videoTrackIDs.contains($0) }
                #expect(!overlappingIDs.isEmpty,
                        "Instruction at \(instruction.timeRange.start.seconds)s with \(instruction.units.count) units must require source track IDs")
            }
        }
    }

    @Test("AVAssetImageGenerator renders a non-black frame through the custom compositor")
    func imageGeneratorRendersNonBlack() async throws {
        let url = try await makeVideoFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let project = Project()
        let media = try await loadedMedia(from: url)
        project.mediaItems.append(media)

        let track = project.videoTracks.first!
        let clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: time(1), timelineStart: .zero)
        track.clips = [clip]

        let built = try #require(try await CompositionBuilder.build(project: project))
        let videoComp = try #require(built.videoComposition)

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = videoComp
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let midTime = CMTime(seconds: 0.5, preferredTimescale: 600)
        let image = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: midTime)]) {
                _, image, _, result, error in
                if let image, result == .succeeded {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "Test", code: -1))
                }
            }
        }

        let luma = try meanLuma(image)
        #expect(luma > 50, "Rendered frame should not be black; got luma \(luma)")
    }

    @Test("AVAssetExportSession produces valid video with the custom compositor")
    func exportProducesValidVideo() async throws {
        let url = try await makeVideoFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-diag-export-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let project = Project()
        let media = try await loadedMedia(from: url)
        project.mediaItems.append(media)

        let track = project.videoTracks.first!
        let clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: time(1), timelineStart: .zero)
        track.clips = [clip]

        let built = try #require(try await CompositionBuilder.build(project: project))
        let videoComp = try #require(built.videoComposition)

        let session = try #require(AVAssetExportSession(
            asset: built.composition,
            presetName: AVAssetExportPresetHighestQuality))
        session.videoComposition = videoComp
        session.outputURL = exportURL
        session.outputFileType = .mov
        try await session.export(to: exportURL, as: .mov)

        // Verify the exported file has video.
        let exported = AVURLAsset(url: exportURL)
        let exportedVideoTracks = try await exported.loadTracks(withMediaType: .video)
        #expect(!exportedVideoTracks.isEmpty, "Exported file must contain video tracks")

        // Sample a frame from the export to verify it's not black.
        let exportedLuma = try await sampledLuma(asset: exported,
                                                  videoComposition: nil,
                                                  at: CMTime(seconds: 0.5, preferredTimescale: 600))
        #expect(exportedLuma > 50, "Exported frame should not be black; got luma \(exportedLuma)")
    }

    @Test("Editor model publishes preview item state after adding video to timeline")
    func editorModelPublishesPreviewItemState() async throws {
        let url = try await makeVideoFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let suiteName = "PreviewVideoDiagnosticsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = EditorModel(defaultsStore: defaults)
        let media = try await loadedMedia(from: url)
        model.project.mediaItems.append(media)

        #expect(!model.hasPreviewItem)
        #expect(model.player.currentItem == nil)

        model.addToTimeline(mediaID: media.id)
        await model.rebuild()

        #expect(model.hasPreviewItem)
        #expect(model.player.currentItem != nil)
        #expect(model.totalDuration > 0)

        model.documentController.newDocument(model: model)

        #expect(!model.hasPreviewItem)
        #expect(model.player.currentItem == nil)
    }

    // MARK: - Helpers

    private func sampledLuma(asset: AVAsset,
                             videoComposition: AVVideoComposition?,
                             at time: CMTime) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, result, error in
                if let image, result == .succeeded {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "Test", code: -3))
                }
            }
        }
        return try meanLuma(image)
    }

    private func meanLuma(_ image: CGImage) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let ctx = context else { throw NSError(domain: "Test", code: -2) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[0]) * 0.299 + Double(pixel[1]) * 0.587 + Double(pixel[2]) * 0.114
    }
}
