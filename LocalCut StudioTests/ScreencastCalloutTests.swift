import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Screencast callout transform keyframes")
struct ScreencastCalloutTransformKeyframeTests {
    @Test("First callout keyframe promotes static transform without double-applying")
    func firstKeyframePromotesStaticTransform() throws {
        let model = EditorModel()
        let calloutID = UUID()
        let start = CMTime(seconds: 2, preferredTimescale: 600)
        model.project.renderSize = CGSize(width: 210, height: 90)
        model.project.callouts = [
            CalloutClip(
                id: calloutID,
                kind: .box,
                timeRange: CMTimeRange(
                    start: start,
                    duration: CMTime(seconds: 4, preferredTimescale: 600)),
                positionOffset: CGSize(width: 42, height: -18),
                scale: 1.75,
                rotation: Float.pi / 6),
        ]
        model.selectedCalloutID = calloutID
        model.currentTime = 3

        model.addOrUpdateSelectedCalloutTransformKeyframe()

        let callout = try #require(model.project.callouts.first)
        #expect(callout.positionOffset.width == 0)
        #expect(callout.positionOffset.height == 0)
        #expect(callout.scale == 1)
        #expect(callout.rotation == 0)
        #expect(callout.transformKeyframes.keyframes.count == 1)

        let keyframe = try #require(callout.transformKeyframes.keyframes.first)
        #expect(abs(keyframe.time.seconds - 1) < 0.001)
        #expect(abs(keyframe.value.tx - 0.2) < 0.001)
        #expect(abs(keyframe.value.ty - -0.2) < 0.001)
        #expect(abs(keyframe.value.decomposedScale - 1.75) < 0.001)
        #expect(abs(keyframe.value.decomposedRotation - Float.pi / 6) < 0.001)
    }

    @Test("Clip transform keyframes can be added edited and removed at the playhead")
    func clipTransformKeyframesAreEditable() throws {
        let model = EditorModel()
        let clip = Clip(
            mediaID: UUID(),
            sourceStart: .zero,
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            timelineStart: .zero)
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id
        model.currentTime = 2

        model.addOrUpdateSelectedClipTransformKeyframe()
        var edited = Transform2D(translateX: 0.125, translateY: -0.08, scale: 1.4, rotation: 0.1)
        model.updateSelectedClipTransformKeyframeValue(edited)

        var updatedClip = try #require(model.project.videoTracks.first?.clips.first)
        var keyframe = try #require(updatedClip.transformKeyframes.keyframes.first)
        #expect(abs(keyframe.time.seconds - 2) < 0.001)
        #expect(abs(keyframe.value.tx - edited.tx) < 0.001)
        #expect(abs(keyframe.value.ty - edited.ty) < 0.001)
        #expect(abs(keyframe.value.decomposedScale - edited.decomposedScale) < 0.001)

        edited = Transform2D(translateX: -0.1, translateY: 0.05, scale: 1.2, rotation: 0)
        model.updateSelectedClipTransformKeyframeValue(edited)
        updatedClip = try #require(model.project.videoTracks.first?.clips.first)
        keyframe = try #require(updatedClip.transformKeyframes.keyframes.first)
        #expect(abs(keyframe.value.tx - edited.tx) < 0.001)

        model.removeSelectedClipTransformKeyframe()
        updatedClip = try #require(model.project.videoTracks.first?.clips.first)
        #expect(updatedClip.transformKeyframes.keyframes.isEmpty)
    }

    @Test("Each callout kind renders a deterministic non-empty snapshot")
    func eachCalloutKindRendersSnapshot() throws {
        let size = CGSize(width: 96, height: 64)
        let source = checkerboardFixture(size: size)
        let sourceBytes = try #require(rgbaBytes(source, size: size))

        let snapshots: [(CalloutKind, CIImage?)] = [
            (.arrow, CalloutRenderer.renderArrow(
                style: ArrowCalloutStyle(strokeWidth: 4),
                startPoint: CGPoint(x: 0.2, y: 0.2),
                endPoint: CGPoint(x: 0.8, y: 0.7),
                renderSize: size)),
            (.box, CalloutRenderer.renderBox(
                style: BoxCalloutStyle(strokeWidth: 4, cornerRadius: 6, fillOpacity: 0.2),
                rect: CGRect(x: 0.18, y: 0.18, width: 0.58, height: 0.48),
                renderSize: size)),
            (.stepNumber, CalloutRenderer.renderStepNumber(
                style: StepNumberCalloutStyle(fontSize: 18, diameter: 34),
                number: 3,
                position: CGPoint(x: 0.5, y: 0.5),
                renderSize: size)),
            (.spotlight, CalloutRenderer.renderSpotlight(
                style: SpotlightCalloutStyle(radius: 0.18, dimOpacity: 0.65, feather: 0.03),
                centre: CGPoint(x: 0.52, y: 0.48),
                sourceImage: source,
                renderSize: size)),
            (.blurRegion, CalloutRenderer.renderBlurRegion(
                style: BlurRegionCalloutStyle(blurRadius: 8, cornerRadius: 4),
                rect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.55),
                sourceImage: source,
                renderSize: size)),
        ]

        for (kind, maybeImage) in snapshots {
            let image = try #require(maybeImage, "\(kind.displayName) should render")
            let bytes = try #require(rgbaBytes(image, size: size), "\(kind.displayName) should render to RGBA")
            switch kind {
            case .arrow, .box, .stepNumber:
                #expect(nonTransparentPixelCount(bytes) > 8, "\(kind.displayName) snapshot should contain visible pixels")
            case .spotlight, .blurRegion:
                #expect(bytes != sourceBytes, "\(kind.displayName) snapshot should change the fixture image")
            }
        }
    }

    @Test("Padded background fits the full foreground into the inset frame")
    func paddedBackgroundFitsForegroundInsteadOfCropping() throws {
        let size = CGSize(width: 100, height: 100)
        let renderRect = CGRect(origin: .zero, size: size)
        let base = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: renderRect)
        let leftEdge = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 10, height: 100))
        let foreground = leftEdge.composited(over: base)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: renderRect)
        let preset = PaddedBackgroundPreset(
            cornerRadius: 0,
            shadowOpacity: 0,
            shadowRadius: 0,
            insetMargin: 20)

        let image = EffectCompositor.paddedBackgroundComposite(
            foreground: foreground,
            background: background,
            preset: preset,
            insetMargin: 20,
            renderSize: size)
        let bytes = try #require(rgbaBytes(image, size: size))
        let edgePixel = try #require(pixel(bytes, width: 100, x: 21, y: 50))
        let backgroundPixel = try #require(pixel(bytes, width: 100, x: 10, y: 50))

        #expect(edgePixel[0] > 200)
        #expect(edgePixel[2] < 80)
        #expect(backgroundPixel[0] < 20)
        #expect(backgroundPixel[1] < 20)
        #expect(backgroundPixel[2] < 20)
    }

    @Test("Imported event log can propose, apply, and export")
    func importedEventLogProposeApplyExportSmoke() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencast-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoURL = try await makeVideoFixture(seconds: 1.2, in: tmp)
        let media = try await loadedMedia(from: videoURL)
        let model = EditorModel()
        model.project.renderSize = CGSize(width: 96, height: 64)
        model.project.mediaItems = [media]

        let clip = Clip(
            mediaID: media.id,
            sourceStart: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            timelineStart: .zero)
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id

        let eventLog = ScreencastEventLog(
            sessionID: UUID(),
            events: [
                ScreencastEvent(
                    time: CMTime(seconds: 0.18, preferredTimescale: 600),
                    kind: .mouseDown,
                    position: CGPoint(x: 0.42, y: 0.46)),
                ScreencastEvent(
                    time: CMTime(seconds: 0.42, preferredTimescale: 600),
                    kind: .mouseDown,
                    position: CGPoint(x: 0.44, y: 0.48)),
            ])
        let eventLogURL = tmp.appendingPathComponent("events.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(eventLog).write(to: eventLogURL, options: .atomic)

        model.importScreencastEventLog(url: eventLogURL)
        let proposal = try #require(model.autoZoomProposals.first)
        #expect(model.project.screencastEventLogs == [eventLog])
        model.applyAutoZoomProposal(proposal)

        let appliedClip = try #require(model.project.videoTracks.first?.clips.first)
        #expect(appliedClip.transformKeyframes.keyframes.count == proposal.keyframes.count)

        let built = try #require(try await CompositionBuilder.build(project: model.project))
        let videoComposition = try #require(built.videoComposition)
        let outputURL = tmp.appendingPathComponent("screencast-smoke-export.mov")
        let session = try #require(AVAssetExportSession(
            asset: built.composition,
            presetName: AVAssetExportPresetHighestQuality))
        session.videoComposition = videoComposition
        session.outputURL = outputURL
        session.outputFileType = .mov
        try await session.export(to: outputURL, as: .mov)

        let exported = AVURLAsset(url: outputURL)
        let tracks = try await exported.loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty, "Imported event-log smoke export must contain video")
    }

    private func checkerboardFixture(size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        let filter = CIFilter(name: "CICheckerboardGenerator")
        filter?.setValue(CIVector(x: size.width / 2, y: size.height / 2), forKey: "inputCenter")
        filter?.setValue(CIColor(red: 0.15, green: 0.2, blue: 0.9, alpha: 1), forKey: "inputColor0")
        filter?.setValue(CIColor(red: 0.9, green: 0.75, blue: 0.15, alpha: 1), forKey: "inputColor1")
        filter?.setValue(8.0, forKey: "inputWidth")
        filter?.setValue(1.0, forKey: "inputSharpness")
        return (filter?.outputImage ?? CIImage(color: .gray)).cropped(to: extent)
    }

    private func rgbaBytes(_ image: CIImage, size: CGSize) -> [UInt8]? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: nil).render(
            image,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: CGRect(origin: .zero, size: size),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }

    private func nonTransparentPixelCount(_ bytes: [UInt8]) -> Int {
        stride(from: 3, to: bytes.count, by: 4).reduce(0) { count, index in
            count + (bytes[index] > 0 ? 1 : 0)
        }
    }

    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8]? {
        let index = (y * width + x) * 4
        guard index >= 0, index + 3 < bytes.count else { return nil }
        return Array(bytes[index..<(index + 4)])
    }

    private func makeVideoFixture(seconds: Double,
                                  fps: Int32 = 30,
                                  in directory: URL,
                                  size: CGSize = CGSize(width: 96, height: 64)) async throws -> URL {
        let url = directory.appendingPathComponent("screencast-fixture-\(UUID().uuidString).mov")
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
                    throw writer.error ?? NSError(domain: "ScreencastCalloutTests", code: -1)
                }
                await Task.yield()
            }
            let buffer = try makePixelBuffer(size: size, adaptor: adaptor, frame: frame)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw writer.error ?? NSError(domain: "ScreencastCalloutTests", code: -2)
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
            throw NSError(domain: "ScreencastCalloutTests", code: -3)
        }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw NSError(domain: "ScreencastCalloutTests", code: Int(status))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "ScreencastCalloutTests", code: -4)
        }
        memset(base, Int32(0x60 + (frame % 24)), CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(size.height))
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
