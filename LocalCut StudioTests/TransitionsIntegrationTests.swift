import Testing
import AVFoundation
import CoreImage
@testable import LocalCut_Studio

/// End-to-end transition tests that build a real `AVComposition` from a
/// generated video fixture, exercising the AVFoundation insertion / ripple path
/// (not just the pure layout math).
@MainActor
@Suite("Transitions — integration")
struct TransitionsIntegrationTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Fixture

    /// Writes a short solid-colour H.264 movie to a temp file and returns its URL.
    private func makeVideoFixture(seconds: Double, fps: Int32 = 30,
                                  size: CGSize = CGSize(width: 64, height: 64)) async throws -> URL {
        // Unique per call — tests in a suite run in parallel and must not share
        // (and clobber) the same fixture file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transition-fixture-\(UUID().uuidString).mov")
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
                // Mid-grey opaque frame.
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

    @Test("Build ripples a real composition: duration shortens by the overlap")
    func buildRipplesRealComposition() async throws {
        let url = try await makeVideoFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let project = Project()
        let media = try await loadedMedia(from: url)
        project.mediaItems.append(media)

        let track = project.videoTracks.first!
        let a = Clip(mediaID: media.id, sourceStart: .zero, duration: time(1), timelineStart: .zero)
        var b = Clip(mediaID: media.id, sourceStart: .zero, duration: time(1), timelineStart: time(1))
        b.transition = Transition(duration: time(0.5))
        track.clips = [a, b]

        let built = try #require(try await CompositionBuilder.build(project: project))

        // Authored total 2s; a 0.5s transition overlaps the two clips → ~1.5s, and
        // both overlapping clips landed on separate composition tracks (no throw).
        #expect(abs(built.duration - 1.5) < 0.05)
        #expect(built.videoComposition != nil)
        // The two clips must occupy two video composition tracks during overlap.
        let videoTracks = built.composition.tracks(withMediaType: .video)
        #expect(videoTracks.count >= 2)
    }

    @Test("Build with no transitions keeps the full duration")
    func buildWithoutTransitionsKeepsDuration() async throws {
        let url = try await makeVideoFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let project = Project()
        let media = try await loadedMedia(from: url)
        project.mediaItems.append(media)

        let track = project.videoTracks.first!
        track.clips = [
            Clip(mediaID: media.id, sourceStart: .zero, duration: time(1), timelineStart: .zero),
            Clip(mediaID: media.id, sourceStart: .zero, duration: time(1), timelineStart: time(1)),
        ]

        let built = try #require(try await CompositionBuilder.build(project: project))
        #expect(abs(built.duration - 2.0) < 0.05)
    }

    @Test("Split at playhead converts effective time to authored under a transition")
    func splitAtPlayheadUnderTransition() async throws {
        let url = try await makeVideoFixture(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel()
        let media = try await loadedMedia(from: url)
        model.project.mediaItems.append(media)

        let track = model.project.videoTracks.first!
        let a = Clip(mediaID: media.id, sourceStart: .zero, duration: time(5), timelineStart: .zero)
        var b = Clip(mediaID: media.id, sourceStart: .zero, duration: time(5), timelineStart: time(5))
        b.transition = Transition(duration: time(1))
        track.clips = [a, b]

        // B is authored [5,10]; the 1s transition ripples it to effective [4,9].
        // A playhead at effective 6s corresponds to authored 7s inside B.
        model.selectedClipID = b.id
        model.currentTime = 6
        model.splitSelectedClipAtPlayhead()

        let ordered = track.clips.sorted { $0.timelineStart < $1.timelineStart }
        #expect(ordered.count == 3)
        // B split at authored 7s → [5,7] and [7,10], NOT at 6s (the naive offset).
        #expect(abs(ordered[1].timelineStart.seconds - 5) < 0.001)
        #expect(abs(ordered[1].timelineEnd.seconds - 7) < 0.001)
        #expect(abs(ordered[2].timelineStart.seconds - 7) < 0.001)
        // The transition stays on the left piece (the one still adjacent to A).
        #expect(ordered[1].transition != nil)
        #expect(ordered[2].transition == nil)
    }
}
