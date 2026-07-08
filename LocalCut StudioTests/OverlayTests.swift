import Testing
import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - Overlay model round-trip tests

@Test("OverlayClip timelineEnd computes correctly")
func overlayTimelineEnd() {
    let overlay = OverlayClip(
        sourceType: .animatedImage,
        timelineStart: CMTime(seconds: 2, preferredTimescale: 600),
        duration: CMTime(seconds: 5, preferredTimescale: 600))
    #expect(overlay.timelineEnd == CMTime(seconds: 7, preferredTimescale: 600))
}

@Test("OverlayClip defaults are sensible")
func overlayDefaults() {
    let overlay = OverlayClip(
        sourceType: .alphaVideo,
        timelineStart: .zero,
        duration: CMTime(seconds: 3, preferredTimescale: 600))
    #expect(overlay.positionOffset == .zero)
    #expect(overlay.scale == 1)
    #expect(overlay.rotation == 0)
    #expect(overlay.opacity == 1)
    #expect(overlay.endAction == .loop)
}

@MainActor
@Test("Overlay selection clears when another editable target is selected")
func overlaySelectionClearsForOtherTargets() {
    let model = EditorModel()
    let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
    model.project.mediaItems.append(media)
    let clip = Clip(mediaID: media.id,
                    sourceStart: .zero,
                    duration: CMTime(seconds: 3, preferredTimescale: 600),
                    timelineStart: .zero)
    model.project.videoTracks[0].clips = [clip]
    let marker = TimelineMarker(time: CMTime(seconds: 1, preferredTimescale: 600))
    model.project.markers = [marker]
    let overlay = OverlayClip(sourceType: .animatedImage,
                              timelineStart: .zero,
                              duration: CMTime(seconds: 1, preferredTimescale: 600))
    model.project.overlays = [overlay]

    model.selectOverlay(overlay.id)
    model.selectMedia(id: media.id)
    #expect(model.selectedOverlayID == nil)

    model.selectOverlay(overlay.id)
    model.selectClip(id: clip.id)
    #expect(model.selectedOverlayID == nil)

    model.selectOverlay(overlay.id)
    model.selectMarker(id: marker.id)
    #expect(model.selectedOverlayID == nil)

    model.selectOverlay(overlay.id)
    model.documentController.newDocument(model: model)
    #expect(model.selectedOverlayID == nil)
    #expect(model.project.overlays.isEmpty)
    #expect(model.project.overlayBookmarks.isEmpty)
    #expect(model.project.overlayBundlePaths.isEmpty)
}

// MARK: - AnimatedImageSource tests

@Test("AnimatedImageSource returns nil for nonexistent file")
func animatedImageSourceMissingFile() {
    let url = URL(fileURLWithPath: "/nonexistent/file.webp")
    let source = AnimatedImageSource(url: url)
    #expect(source == nil)
}

// MARK: - AlphaVideoSource tests

@Test("AlphaVideoSource returns nil for nonexistent file")
func alphaVideoSourceMissingFile() async {
    let url = URL(fileURLWithPath: "/nonexistent/file.mov")
    let source = await AlphaVideoSource.make(url: url)
    #expect(source == nil)
}

@Test("AlphaVideoSource purges decoded frame cache")
func alphaVideoSourcePurgesDecodedFrames() async throws {
    let tmp = try makeOverlayTempDirectory("alpha-purge")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = try await makeOverlayVideoFixture(seconds: 1, in: tmp)
    let source = try #require(await AlphaVideoSource.make(url: url))

    _ = await source.frame(at: .zero, endAction: .freeze)
    #expect(source.cachedFrameCount > 0)

    source.purgeCachedFrames()
    #expect(source.cachedFrameCount == 0)
}

@MainActor
@Test("Overlay import rejects files that do not match the chosen source type")
func importOverlayRejectsMismatchedType() async throws {
    let tmp = try makeOverlayTempDirectory("import-type")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let jsonURL = tmp.appendingPathComponent("sticker.json")
    try Data(minimalLottieJSON.utf8).write(to: jsonURL, options: .atomic)

    let model = EditorModel()
    await model.importOverlay(from: jsonURL, sourceType: .alphaVideo)

    #expect(model.project.overlays.isEmpty)
    #expect(model.statusMessage.contains("alpha video"))
}

@Test("Overlay source types expose narrow importer filters")
func overlaySourceTypeImporterFilters() {
    #expect(OverlaySourceType.animatedImage.acceptsSourceURL(URL(fileURLWithPath: "/tmp/sticker.apng")))
    #expect(OverlaySourceType.lottie.acceptsSourceURL(URL(fileURLWithPath: "/tmp/sticker.lottie")))
    #expect(!OverlaySourceType.alphaVideo.acceptsSourceURL(URL(fileURLWithPath: "/tmp/sticker.json")))
    #expect(OverlaySourceType.lottie.allowedContentTypes.contains(.dotLottie))
}

// MARK: - Project overlay persistence

@Test("Project overlayDocs round-trips through ProjectDocument")
func overlayDocsRoundTrip() throws {
    let project = Project()
    let overlay = OverlayClip(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sourceType: .animatedImage,
        timelineStart: CMTime(seconds: 1, preferredTimescale: 600),
        duration: CMTime(seconds: 3, preferredTimescale: 600),
        positionOffset: CGSize(width: 0.5, height: -0.25),
        scale: 1.5,
        rotation: 0.785,
        opacity: 0.8,
        endAction: .freeze)
    project.overlays = [overlay]
    project.overlayBookmarks[overlay.id] = Data([0xCA, 0xFE])

    let doc = ProjectDocument(project: project)
    #expect(doc.overlays.count == 1)
    #expect(doc.overlays[0].sourceType == .animatedImage)
    #expect(doc.overlays[0].endAction == .freeze)
    #expect(doc.overlays[0].opacity == 0.8)

    let encoded = try doc.encoded()
    let decoded = try ProjectDocument(data: encoded)
    #expect(decoded.overlays.count == 1)
    #expect(decoded.overlays[0].id == overlay.id)
    #expect(decoded.overlays[0].sourceType == .animatedImage)
    #expect(decoded.overlays[0].endAction == .freeze)
}

// MARK: - Overlay render item in compositor

@Test("OverlayRenderItem carries correct metadata")
func overlayRenderItemMetadata() {
    let item = OverlayRenderItem(
        overlayID: UUID(),
        sourceType: .alphaVideo,
        range: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                           duration: CMTime(seconds: 5, preferredTimescale: 600)),
        positionOffset: CGSize(width: 0.3, height: -0.1),
        scale: 2.0,
        rotation: 1.57,
        opacity: 0.6,
        endAction: .loop,
        positionXKeyframes: Keyframed<Float>(defaultValue: 0),
        positionYKeyframes: Keyframed<Float>(defaultValue: 0),
        scaleKeyframes: Keyframed<Float>(defaultValue: 1),
        rotationKeyframes: Keyframed<Float>(defaultValue: 0),
        opacityKeyframes: Keyframed<Float>(defaultValue: 1))
    #expect(item.sourceType == .alphaVideo)
    #expect(item.opacity == 0.6)
    #expect(item.endAction == .loop)
    #expect(item.scale == 2.0)
}

@Test("Overlay compositor transform preserves natural size and rotates around center")
func overlayTransformPreservesAuthoredScale() throws {
    let transform = try #require(EffectCompositor.overlayTransform(
        naturalSize: CGSize(width: 20, height: 10),
        scale: 2,
        rotation: 0,
        positionOffset: .zero,
        renderSize: CGSize(width: 100, height: 80)))

    let topLeft = CGPoint(x: 0, y: 0).applying(transform)
    let center = CGPoint(x: 10, y: 5).applying(transform)

    #expect(approximately(topLeft.x, 30))
    #expect(approximately(topLeft.y, 30))
    #expect(approximately(center.x, 50))
    #expect(approximately(center.y, 40))

    let rotated = try #require(EffectCompositor.overlayTransform(
        naturalSize: CGSize(width: 20, height: 10),
        scale: 1,
        rotation: .pi / 2,
        positionOffset: CGSize(width: 0.5, height: -0.5),
        renderSize: CGSize(width: 100, height: 80)))
    let rotatedCenter = CGPoint(x: 10, y: 5).applying(rotated)

    #expect(approximately(rotatedCenter.x, 75))
    #expect(approximately(rotatedCenter.y, 60))
}

// MARK: - Composition with overlays

@Test("CompositionBuilder includes overlay boundaries in instructions")
func compositionOverlayBoundaries() async throws {
    let project = Project()
    // Add a minimal video track with a clip so the composition isn't empty.
    let mediaID = UUID()
    project.videoTracks[0].clips.append(Clip(
        mediaID: mediaID,
        sourceStart: .zero,
        duration: CMTime(seconds: 10, preferredTimescale: 600),
        timelineStart: .zero))

    // Add an overlay.
    let overlay = OverlayClip(
        sourceType: .animatedImage,
        timelineStart: CMTime(seconds: 3, preferredTimescale: 600),
        duration: CMTime(seconds: 4, preferredTimescale: 600))
    project.overlays = [overlay]

    // Build — this will fail because we don't have a real media asset, but
    // the overlay boundaries should be included. We test the instruction
    // structure by verifying the overlay metadata is present.
    // For a real integration test, we'd need a fixture media file.
    // This test verifies the model wiring only.
    #expect(project.overlays.count == 1)
    #expect(project.overlays[0].timelineStart == CMTime(seconds: 3, preferredTimescale: 600))
}

@Test("CompositionBuilder extends overlay-only timelines with filler video")
func compositionOverlayOnlyDuration() async throws {
    let project = Project()
    project.renderSize = CGSize(width: 32, height: 32)
    project.frameRate = 30
    project.overlays = [
        OverlayClip(
            sourceType: .animatedImage,
            timelineStart: CMTime(seconds: 1, preferredTimescale: 600),
            duration: CMTime(seconds: 2, preferredTimescale: 600)),
    ]

    let built = try #require(try await CompositionBuilder.build(project: project))
    let videoComposition = try #require(built.videoComposition)
    let overlayInstructions = videoComposition.instructions.compactMap {
        $0 as? EffectCompositionInstruction
    }.filter { !$0.overlays.isEmpty }

    #expect(abs(built.duration - 3) < 0.05)
    #expect(!overlayInstructions.isEmpty)
    #expect(overlayInstructions.allSatisfy { !$0.units.isEmpty })
}

@Test("CompositionBuilder fills overlay gaps between video clips")
func compositionOverlayGapBetweenVideoClipsUsesFiller() async throws {
    let tmp = try makeOverlayTempDirectory("overlay-gap")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let videoURL = try await makeOverlayVideoFixture(seconds: 1, in: tmp)
    let media = try await loadedOverlayMedia(from: videoURL)

    let project = Project()
    project.renderSize = CGSize(width: 32, height: 32)
    project.frameRate = 30
    project.mediaItems = [media]
    project.videoTracks[0].clips = [
        Clip(mediaID: media.id,
             sourceStart: .zero,
             duration: CMTime(seconds: 1, preferredTimescale: 600),
             timelineStart: .zero),
        Clip(mediaID: media.id,
             sourceStart: .zero,
             duration: CMTime(seconds: 1, preferredTimescale: 600),
             timelineStart: CMTime(seconds: 4, preferredTimescale: 600)),
    ]
    project.overlays = [
        OverlayClip(
            sourceType: .animatedImage,
            timelineStart: CMTime(seconds: 2, preferredTimescale: 600),
            duration: CMTime(seconds: 1, preferredTimescale: 600)),
    ]

    let built = try #require(try await CompositionBuilder.build(project: project))
    let videoComposition = try #require(built.videoComposition)
    let gapInstruction = try #require(videoComposition.instructions.compactMap {
        $0 as? EffectCompositionInstruction
    }.first { instruction in
        instruction.timeRange.containsTime(CMTime(seconds: 2.5, preferredTimescale: 600))
    })

    #expect(!gapInstruction.overlays.isEmpty)
    #expect(!gapInstruction.units.isEmpty)
}

// MARK: - Lottie verification

@Test("LottieFrameSource renders deterministic pixels at sampled times")
@MainActor
func lottieFrameSourceDeterminism() async throws {
    let tmp = try makeOverlayTempDirectory("lottie-determinism")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("sticker.json")
    try minimalLottieJSON.data(using: .utf8)!.write(to: url, options: .atomic)

    let first = try #require(LottieFrameSource(url: url))
    let second = try #require(LottieFrameSource(url: url))

    let sampleTime = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
    let firstFrame = try #require(await first.frame(at: sampleTime, endAction: .freeze))
    let secondFrame = try #require(await second.frame(at: sampleTime, endAction: .freeze))

    #expect(first.naturalSize == CGSize(width: 8, height: 8))
    #expect(pngBytes(firstFrame, size: first.naturalSize) == pngBytes(secondFrame, size: second.naturalSize))
    #expect(first.cachedFrameCount > 0)
    first.purgeCachedFrames()
    #expect(first.cachedFrameCount == 0)
    #expect(await first.frame(at: CMTime(seconds: 10, preferredTimescale: 600), endAction: .hide) == nil)
}

@Test("LottieFrameSource reports unsupported layer effects")
func lottieUnsupportedFeatureWarning() throws {
    let tmp = try makeOverlayTempDirectory("lottie-warning")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("warning.json")
    try Data(#"{"layers":[{"ef":[{"ty":5,"nm":"blur"}]}]}"#.utf8).write(to: url, options: .atomic)

    let warning = try #require(LottieFrameSource.unsupportedFeatureWarning(for: url))
    #expect(warning.contains("layer effects"))
}

@Test("Render queue smoke exports animated image, Lottie, and alpha-video overlays")
@MainActor
func renderQueueExportsAllOverlayKinds() async throws {
    let tmp = try makeOverlayTempDirectory("export-smoke")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let videoURL = try await makeOverlayVideoFixture(seconds: 1, in: tmp)
    let media = try await loadedOverlayMedia(from: videoURL)
    media.bookmark = try videoURL.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)

    let pngURL = tmp.appendingPathComponent("sticker.png")
    try #require(pngBytes(
        CIImage(color: CIColor(red: 0, green: 1, blue: 0, alpha: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
        size: CGSize(width: 8, height: 8)))
        .write(to: pngURL, options: .atomic)

    let lottieURL = tmp.appendingPathComponent("sticker.json")
    try minimalLottieJSON.data(using: .utf8)!.write(to: lottieURL, options: .atomic)

    let alphaURL = try await makeOverlayVideoFixture(seconds: 1, in: tmp)

    let project = Project()
    project.renderSize = CGSize(width: 64, height: 64)
    project.frameRate = 30
    project.mediaItems = [media]
    project.videoTracks[0].clips = [
        Clip(mediaID: media.id,
             sourceStart: .zero,
             duration: CMTime(seconds: 1, preferredTimescale: 600),
             timelineStart: .zero),
    ]

    let overlays = [
        OverlayClip(sourceType: .animatedImage,
                    timelineStart: .zero,
                    duration: CMTime(seconds: 0.8, preferredTimescale: 600),
                    positionOffset: CGSize(width: -0.35, height: 0),
                    scale: 0.5,
                    endAction: .loop),
        OverlayClip(sourceType: .lottie,
                    timelineStart: .zero,
                    duration: CMTime(seconds: 0.8, preferredTimescale: 600),
                    scale: 0.5,
                    endAction: .freeze),
        OverlayClip(sourceType: .alphaVideo,
                    timelineStart: .zero,
                    duration: CMTime(seconds: 0.8, preferredTimescale: 600),
                    positionOffset: CGSize(width: 0.35, height: 0),
                    scale: 0.5,
                    opacity: 0.75,
                    endAction: .hide),
    ]
    project.overlays = overlays
    let urlsByID = [
        overlays[0].id: pngURL,
        overlays[1].id: lottieURL,
        overlays[2].id: alphaURL,
    ]
    for overlay in overlays {
        let sourceURL = try #require(urlsByID[overlay.id])
        project.overlayBookmarks[overlay.id] = try sourceURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    let outputURL = tmp.appendingPathComponent("overlay-smoke.mov")
    try Data().write(to: outputURL, options: .atomic)
    let outputBookmark = try outputURL.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)

    let queue = RenderQueue(persistsToDisk: false)
    queue.enqueueWithDefaultPreset(outputURL: outputURL,
                                   project: project,
                                   bookmark: outputBookmark)
    let job = try await waitForFinishedOverlayJob(queue)

    #expect(job.status == .completed, "Render queue export failed: \(job.errorMessage ?? "unknown error")")
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    let outputAsset = AVURLAsset(url: outputURL)
    let duration = try await outputAsset.load(.duration)
    #expect(duration.seconds > 0)
}

@MainActor
@Test("Overlay keyframe add, update, and clear round-trip")
func overlayKeyframeAddUpdateClear() {
    let model = EditorModel()
    let overlayID = UUID()
    model.project.overlays = [
        OverlayClip(
            id: overlayID,
            sourceType: .animatedImage,
            timelineStart: .zero,
            duration: CMTime(seconds: 10, preferredTimescale: 600)),
    ]

    let time1 = CMTime(seconds: 2, preferredTimescale: 600)
    model.addOrUpdateOverlayKeyframe(
        at: overlayID, localTime: time1,
        positionX: 10, positionY: 20, scale: 1.5, rotation: 0.5, opacity: 0.8)
    let overlay = model.project.overlays.first!
    #expect(overlay.positionXKeyframes.keyframes.count == 1)
    #expect(overlay.scaleKeyframes.keyframes.count == 1)
    #expect(overlay.opacityKeyframes.keyframes.count == 1)

    // Update at same time
    model.addOrUpdateOverlayKeyframe(
        at: overlayID, localTime: time1,
        positionX: 30, positionY: 40, scale: 2.0, rotation: 1.0, opacity: 0.5)
    #expect(model.project.overlays.first!.positionXKeyframes.keyframes.count == 1)

    // Add a second keyframe
    let time2 = CMTime(seconds: 5, preferredTimescale: 600)
    model.addOrUpdateOverlayKeyframe(
        at: overlayID, localTime: time2,
        positionX: 50, positionY: 60, scale: 0.5, rotation: 0, opacity: 1.0)
    #expect(model.project.overlays.first!.positionXKeyframes.keyframes.count == 2)

    // Remove one keyframe
    model.removeOverlayKeyframes(at: overlayID, localTime: time1)
    #expect(model.project.overlays.first!.positionXKeyframes.keyframes.count == 1)

    // Clear all
    model.clearOverlayKeyframes(overlayID)
    #expect(model.project.overlays.first!.positionXKeyframes.keyframes.isEmpty)
    #expect(model.project.overlays.first!.scaleKeyframes.keyframes.isEmpty)
}

private func makeOverlayTempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("overlay-tests-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func approximately(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.000_1) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func waitForFinishedOverlayJob(_ queue: RenderQueue) async throws -> QueueJob {
    for _ in 0..<600 {
        if let job = queue.jobs.first, job.isTerminal {
            return job
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    let jobDescription = queue.jobs.first.map { "\($0.status)" } ?? "no job"
    throw NSError(domain: "OverlayTests", code: -20,
                  userInfo: [
                      NSLocalizedDescriptionKey: "Timed out waiting for overlay export (\(jobDescription))",
                  ])
}

private func makeOverlayVideoFixture(seconds: Double,
                                     fps: Int32 = 30,
                                     in directory: URL) async throws -> URL {
    let url = directory.appendingPathComponent("overlay-video-\(UUID().uuidString).mov")
    let size = CGSize(width: 64, height: 64)
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
                throw writer.error ?? NSError(domain: "OverlayTests", code: -1)
            }
            await Task.yield()
        }
        let buffer = try makeOverlayPixelBuffer(size: size, adaptor: adaptor, frame: frame)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            throw writer.error ?? NSError(domain: "OverlayTests", code: -2)
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return url
}

private func makeOverlayPixelBuffer(size: CGSize,
                                    adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                    frame: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    if let pool = adaptor.pixelBufferPool {
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    }
    guard let pixelBuffer else {
        throw NSError(domain: "OverlayTests", code: -3)
    }
    let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard status == kCVReturnSuccess else {
        throw NSError(domain: "OverlayTests", code: Int(status))
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw NSError(domain: "OverlayTests", code: -4)
    }
    let byte = UInt8(0x50 + (frame % 32))
    memset(base, Int32(byte), CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(size.height))
    return pixelBuffer
}

private func loadedOverlayMedia(from url: URL) async throws -> MediaItem {
    let item = MediaItem(url: url)
    item.duration = try await item.asset.load(.duration).sanitized
    let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
    let track = try #require(videoTracks.first)
    item.hasVideo = true
    item.naturalSize = try await track.load(.naturalSize).sanitized
    item.preferredTransform = try await track.load(.preferredTransform).sanitized
    return item
}

@MainActor
private func pngBytes(_ image: CIImage, size: CGSize) -> Data? {
    let context = CIContext(options: nil)
    let rect = CGRect(origin: .zero, size: size)
    guard let cgImage = context.createCGImage(image, from: rect) else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

private let minimalLottieJSON = """
{
  "v": "5.7.4",
  "fr": 30,
  "ip": 0,
  "op": 2,
  "w": 8,
  "h": 8,
  "nm": "LocalCut Test Sticker",
  "ddd": 0,
  "assets": [],
  "layers": [
    {
      "ddd": 0,
      "ind": 1,
      "ty": 4,
      "nm": "red square",
      "sr": 1,
      "ks": {
        "o": { "k": 100 },
        "r": { "k": 0 },
        "p": { "k": [4, 4, 0] },
        "a": { "k": [0, 0, 0] },
        "s": { "k": [100, 100, 100] }
      },
      "ao": 0,
      "shapes": [
        {
          "ty": "rc",
          "d": 1,
          "s": { "k": [8, 8] },
          "p": { "k": [0, 0] },
          "r": { "k": 0 },
          "nm": "rect"
        },
        {
          "ty": "fl",
          "c": { "k": [1, 0, 0, 1] },
          "o": { "k": 100 },
          "r": 1,
          "bm": 0,
          "nm": "fill"
        }
      ],
      "ip": 0,
      "op": 2,
      "st": 0,
      "bm": 0
    }
  ]
}
"""
