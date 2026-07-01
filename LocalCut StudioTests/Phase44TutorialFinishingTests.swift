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
        #expect(ChapterExporter.chapterTimedMetadataGroups(
            from: model.project.markers,
            projectDuration: model.project.duration).count == 3)
        #expect(ChapterExporter.chapterMetadataFormatDescription() != nil)

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

    @Test("Silence proposals from trimmed retimed clips map into timeline time")
    func silenceProposalsMapTrimmedRetimedClipsToTimeline() throws {
        let clip = Clip(
            mediaID: UUID(),
            sourceStart: time(10),
            duration: time(4),
            timelineStart: time(30),
            speedCurve: Keyframed(defaultValue: Float(2)))
        let proposal = ProposedCut(
            silenceRange: CMTimeRange(start: time(1), duration: time(1)),
            unpaddedSilenceRange: CMTimeRange(start: time(1.25), duration: time(0.5)))

        let mapped = try #require(EditorModel.timelineProposal(proposal, for: clip))

        #expect(approximatelyEqual(mapped.silenceRange.start.seconds, 30.5))
        #expect(approximatelyEqual(mapped.silenceRange.duration.seconds, 0.5))
        #expect(approximatelyEqual(mapped.unpaddedSilenceRange.start.seconds, 30.625))
        #expect(approximatelyEqual(mapped.unpaddedSilenceRange.duration.seconds, 0.25))
    }

    @Test("Silence cuts ripple timeline annotations and virtual clips")
    func silenceCutsRippleTimelineAnnotationsAndVirtualClips() {
        let model = EditorModel()
        let mediaID = UUID()
        model.project.videoTracks[0].clips = [
            Clip(mediaID: mediaID, sourceStart: .zero, duration: time(10), timelineStart: .zero),
        ]
        model.project.markers = [
            TimelineMarker(time: time(7), name: "After", kind: .chapter),
        ]
        model.project.overlays = [
            OverlayClip(sourceType: .animatedImage, timelineStart: time(7), duration: time(2)),
        ]
        model.project.callouts = [
            CalloutClip(kind: .box, timeRange: CMTimeRange(start: time(7), duration: time(2))),
        ]
        model.project.keystrokeOverlayClips = [
            KeystrokeOverlayClip(
                sourceSessionID: UUID(),
                timeRange: CMTimeRange(start: .zero, duration: time(10)),
                events: [
                    KeystrokeOverlayEvent(time: time(3), displayText: "A", displayMode: .character),
                    KeystrokeOverlayEvent(time: time(5), displayText: "B", displayMode: .character),
                    KeystrokeOverlayEvent(time: time(8), displayText: "C", displayMode: .character),
                ]),
        ]
        let captionTrack = CaptionTrack(name: "Captions", lines: [
            CaptionLine(
                range: CMTimeRange(start: time(3), duration: time(4)),
                text: "Before after",
                words: [
                    WordTiming(range: CMTimeRange(start: time(5), duration: time(0.5)), word: "cut"),
                    WordTiming(range: CMTimeRange(start: time(6.5), duration: time(0.5)), word: "after"),
                ]),
        ])
        model.project.captionTracks = [captionTrack]

        model.silenceProposals = [
            ProposedCut(
                silenceRange: CMTimeRange(start: time(4), duration: time(2)),
                unpaddedSilenceRange: CMTimeRange(start: time(4), duration: time(2))),
        ]
        model.applySelectedSilenceProposals()

        #expect(approximatelyEqual(model.project.duration.seconds, 8))
        #expect(approximatelyEqual(model.project.markers[0].time.seconds, 5))
        #expect(approximatelyEqual(model.project.overlays[0].timelineStart.seconds, 5))
        #expect(approximatelyEqual(model.project.callouts[0].timeRange.start.seconds, 5))
        #expect(approximatelyEqual(model.project.captionTracks[0].lines[0].range.start.seconds, 3))
        #expect(approximatelyEqual(model.project.captionTracks[0].lines[0].range.duration.seconds, 2))
        #expect(model.project.captionTracks[0].lines[0].words?.map(\.word) == ["after"])
        #expect(model.project.keystrokeOverlayClips[0].events.map(\.displayText) == ["A", "C"])
        #expect(model.project.keystrokeOverlayClips[0].events.map { $0.time.seconds } == [3, 6])
    }

    @Test("Silence splits rebase clip volume automation")
    func silenceSplitRebasesClipVolumeAutomation() throws {
        let model = EditorModel()
        let mediaID = UUID()
        var clip = Clip(mediaID: mediaID, sourceStart: .zero, duration: time(10), timelineStart: .zero)
        clip.volumeEnvelope = VolumeEnvelope(
            fadeIn: time(1),
            fadeOut: time(1),
            ramps: [
                VolumeEnvelope.Ramp(
                    range: CMTimeRange(start: time(6), duration: time(2)),
                    fromVolume: 0.2,
                    toVolume: 0.8),
            ])
        model.project.videoTracks[0].clips = [clip]
        model.silenceProposals = [
            ProposedCut(
                silenceRange: CMTimeRange(start: time(4), duration: time(2)),
                unpaddedSilenceRange: CMTimeRange(start: time(4), duration: time(2))),
        ]

        model.applySelectedSilenceProposals()

        let clips = model.project.videoTracks[0].clips.sorted { $0.timelineStart < $1.timelineStart }
        #expect(clips.count == 2)
        let left = try #require(clips.first)
        let right = try #require(clips.last)

        #expect(left.duration == time(4))
        #expect(left.volumeEnvelope.fadeIn == time(1))
        #expect(left.volumeEnvelope.fadeOut == .zero)
        #expect(left.volumeEnvelope.ramps.isEmpty)

        #expect(right.sourceStart == time(6))
        #expect(right.timelineStart == time(4))
        #expect(right.duration == time(4))
        #expect(right.volumeEnvelope.fadeIn == .zero)
        #expect(right.volumeEnvelope.fadeOut == time(1))
        let ramp = try #require(right.volumeEnvelope.ramps.first)
        #expect(ramp.range.start == .zero)
        #expect(ramp.range.duration == time(2))
        #expect(abs(ramp.fromVolume - 0.2) < 0.0001)
        #expect(abs(ramp.toVolume - 0.8) < 0.0001)
    }

    @Test("Keystroke overlays participate in the shared video composition")
    func keystrokeOverlaysParticipateInVideoComposition() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase44-keystrokes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoURL = try await makeVideoFixture(seconds: 2, fps: 2, in: tmp)
        let media = try await loadedMedia(from: videoURL)
        let model = EditorModel()
        model.project.renderSize = CGSize(width: 64, height: 36)
        model.project.frameRate = 2
        model.project.mediaItems = [media]
        model.project.videoTracks[0].clips = [
            Clip(mediaID: media.id, sourceStart: .zero, duration: time(2), timelineStart: .zero),
        ]
        model.project.keystrokeOverlayClips = [
            KeystrokeOverlayClip(
                sourceSessionID: UUID(),
                timeRange: CMTimeRange(start: .zero, duration: time(2)),
                events: [
                    KeystrokeOverlayEvent(time: time(0.5), displayText: "A", displayMode: .character),
                ]),
        ]

        let built = try #require(try await CompositionBuilder.build(project: model.project))
        let instruction = try #require(built.videoComposition?.instructions
            .compactMap { $0 as? EffectCompositionInstruction }
            .first { $0.timeRange.containsTime(time(0.5)) })

        #expect(instruction.keystrokeOverlays.count == 1)
        #expect(KeystrokeOverlayRenderer.render(
            events: instruction.keystrokeOverlays[0].events,
            style: instruction.keystrokeOverlays[0].style,
            currentTime: time(0.6),
            renderSize: model.project.renderSize,
            overlayOpacity: instruction.keystrokeOverlays[0].opacity) != nil)
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
