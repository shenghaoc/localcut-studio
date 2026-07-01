import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Phase 44 — tutorial finishing smoke", .serialized)
struct Phase44TutorialFinishingTests {

    @Test("Silence review can apply, undo, reapply, and export chapters")
    func silenceReviewApplyUndoReapplyExportChaptersSmoke() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase44-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoURL = try await makeVideoFixture(seconds: 32, fps: 2, in: tmp)
        let media = try await loadedMedia(from: videoURL)
        let model = EditorModel()
        model.project.renderSize = CGSize(width: 64, height: 36)
        model.project.frameRate = 2
        model.project.mediaItems = [media]
        model.project.videoTracks[0].clips = [
            Clip(
                mediaID: media.id,
                sourceStart: .zero,
                duration: time(31),
                timelineStart: .zero),
        ]

        let (_, proposals) = SilenceDetectionCore.analyze(
            samples: silenceFixtureSamples(),
            sampleRate: 100,
            parameters: SilenceDetectionParameters(
                openThresholdDB: -40,
                closeThresholdDB: -35,
                minimumSilenceDuration: time(0.5),
                padding: .zero))
        model.silenceProposals = proposals
        model.applySelectedSilenceProposals()

        #expect(model.canUndo)
        #expect(model.silenceProposals.isEmpty)
        #expect(approximatelyEqual(model.project.duration.seconds, 30))
        #expect(model.project.videoTracks[0].clips.count == 2)

        model.undo()
        #expect(approximatelyEqual(model.project.duration.seconds, 31))
        #expect(model.project.videoTracks[0].clips.count == 1)

        model.silenceProposals = proposals
        model.applySelectedSilenceProposals()
        #expect(approximatelyEqual(model.project.duration.seconds, 30))

        model.project.markers = [
            TimelineMarker(time: .zero, name: "Intro", kind: .chapter),
            TimelineMarker(time: time(10), name: "Demo", kind: .chapter),
            TimelineMarker(time: time(20), name: "Wrap", kind: .chapter),
        ]
        let chapters = YouTubeChapterValidator.chapters(
            from: model.project.markers,
            projectDuration: model.project.duration)
        #expect(YouTubeChapterValidator.validate(chapters, projectDuration: model.project.duration).isEmpty)

        let built = try #require(try await CompositionBuilder.build(project: model.project))
        let outputURL = tmp.appendingPathComponent("phase44-smoke.mov")
        let session = try #require(AVAssetExportSession(
            asset: built.composition,
            presetName: AVAssetExportPresetHighestQuality))
        session.videoComposition = built.videoComposition
        session.metadata = ChapterExporter.chapterMetadataItems(
            from: model.project.markers,
            projectDuration: model.project.duration)
        session.outputURL = outputURL
        session.outputFileType = .mov
        try await session.export(to: outputURL, as: .mov)

        let sidecar = ChapterExporter.writeYouTubeSidecar(
            markers: model.project.markers,
            projectDuration: model.project.duration,
            outputURL: outputURL)
        let sidecarPath = try #require(sidecar.sidecarPath)
        let sidecarText = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        let exported = AVURLAsset(url: outputURL)
        let exportedTracks = try await exported.loadTracks(withMediaType: .video)

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(!exportedTracks.isEmpty)
        #expect(sidecar.issues.isEmpty)
        #expect(sidecarText == """
        00:00 Intro
        00:10 Demo
        00:20 Wrap
        """)
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 0.001) -> Bool {
        abs(a - b) <= tolerance
    }

    private func silenceFixtureSamples() -> [Float] {
        [Float](repeating: 0.08, count: 1_000) +
        [Float](repeating: 0, count: 100) +
        [Float](repeating: 0.08, count: 2_000)
    }

    private func makeVideoFixture(seconds: Double,
                                  fps: Int32,
                                  in directory: URL,
                                  size: CGSize = CGSize(width: 64, height: 36)) async throws -> URL {
        let url = directory.appendingPathComponent("phase44-fixture-\(UUID().uuidString).mov")
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
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * Double(fps))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw writer.error ?? NSError(domain: "Phase44TutorialFinishingTests", code: -1)
                }
                await Task.yield()
            }
            let buffer = try makePixelBuffer(size: size, adaptor: adaptor, frame: frame)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw writer.error ?? NSError(domain: "Phase44TutorialFinishingTests", code: -2)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    private func makePixelBuffer(size: CGSize,
                                 adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                 frame: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        guard let pixelBuffer else {
            throw NSError(domain: "Phase44TutorialFinishingTests", code: -3)
        }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw NSError(domain: "Phase44TutorialFinishingTests", code: Int(status))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "Phase44TutorialFinishingTests", code: -4)
        }
        memset(base, Int32(0x40 + (frame % 64)), CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(size.height))
        return pixelBuffer
    }

    private func loadedMedia(from url: URL) async throws -> MediaItem {
        let item = MediaItem(url: url)
        item.duration = try await item.asset.load(.duration).sanitized
        let tracks = try await item.asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        item.hasVideo = true
        item.naturalSize = try await track.load(.naturalSize).sanitized
        item.preferredTransform = try await track.load(.preferredTransform).sanitized
        return item
    }
}
