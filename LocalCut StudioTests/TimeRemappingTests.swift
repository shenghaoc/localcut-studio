import Testing
import AVFoundation
import CoreImage
import LocalCutCore
@testable import LocalCut_Studio

private func trTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func approx(_ lhs: CMTime, _ rhs: CMTime, tolerance: Double = 1e-6) -> Bool {
    abs((lhs - rhs).seconds) < tolerance
}

private func makeTimeRemapVideoFixture(seconds: Double,
                                       fps: Int32 = 30,
                                       size: CGSize = CGSize(width: 64, height: 64)) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("time-remap-fixture-\(UUID().uuidString).mov")
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

private func loadedTimeRemapMedia(from url: URL) async throws -> MediaItem {
    let item = MediaItem(url: url)
    item.duration = try await item.asset.load(.duration)
    let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
    let track = try #require(videoTracks.first)
    item.hasVideo = true
    item.naturalSize = try await track.load(.naturalSize)
    item.preferredTransform = try await track.load(.preferredTransform)
    return item
}

@Test("TimeRemapping: default clip is identity and preserves pitch")
func timeRemapDefaultClipIsIdentity() {
    let clip = Clip(mediaID: UUID(), sourceStart: .zero,
                    duration: trTime(8), timelineStart: trTime(3))

    #expect(!clip.hasTimeRemap)
    #expect(approx(clip.outputDuration, trTime(8)))
    #expect(approx(clip.timelineEnd, trTime(11)))
    #expect(clip.preservePitch)
    #expect(clip.pitchAlgorithm == .timeDomain)
}

@Test("TimeRemapping: constant speed changes output duration")
func timeRemapConstantSpeedChangesOutputDuration() {
    var clip = Clip(mediaID: UUID(), sourceStart: trTime(2),
                    duration: trTime(8), timelineStart: .zero)
    clip.speedCurve.defaultValue = 2
    clip.clampTimeRemap()

    let plan = TimeRemapping.segmentPlan(for: clip)
    #expect(plan.count == 1)
    #expect(approx(plan[0].sourceRange.start, trTime(2)))
    #expect(approx(plan[0].sourceRange.duration, trTime(8)))
    #expect(approx(plan[0].outputDuration, trTime(4)))
    #expect(approx(clip.outputDuration, trTime(4)))
}

@Test("TimeRemapping: speed values clamp to supported range")
func timeRemapClampsSpeedValues() {
    var curve = Keyframed<Float>(defaultValue: 12)
    curve.addKeyframe(at: trTime(0), value: -5)
    curve.addKeyframe(at: trTime(1), value: .nan)

    let clamped = TimeRemapping.clampedCurve(curve)

    #expect(clamped.defaultValue == TimeRemapping.maxSpeed)
    #expect(clamped.keyframes[0].value == TimeRemapping.minSpeed)
    #expect(clamped.keyframes[1].value == TimeRemapping.identitySpeed)
}

@Test("TimeRemapping: animated pair emits ten deterministic subsegments")
func timeRemapAnimatedPairBuildsDeterministicSegments() {
    let curve = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 1),
            Keyframe(time: trTime(10), value: 3),
        ],
        defaultValue: 1)

    let first = TimeRemapping.segmentPlan(sourceDuration: trTime(10), speedCurve: curve)
    let second = TimeRemapping.segmentPlan(sourceDuration: trTime(10), speedCurve: curve)

    #expect(first.count == TimeRemapping.defaultSegmentsPerKeyframePair)
    #expect(first == second)
    #expect(first.allSatisfy { $0.speed >= TimeRemapping.minSpeed && $0.speed <= TimeRemapping.maxSpeed })
}

@Test("TimeRemapping: output and source offsets map through the speed plan")
func timeRemapSourceOutputMapping() {
    var clip = Clip(mediaID: UUID(), sourceStart: .zero,
                    duration: trTime(10), timelineStart: .zero)
    clip.speedCurve.defaultValue = 2
    clip.clampTimeRemap()

    #expect(approx(clip.sourceOffset(forOutputOffset: trTime(2)), trTime(4)))
    #expect(approx(clip.outputOffset(forSourceOffset: trTime(6)), trTime(3)))
}

@MainActor
@Test("TimeRemapping: CompositionBuilder scales a real retimed video composition")
func timeRemapCompositionBuilderScalesVideo() async throws {
    let url = try await makeTimeRemapVideoFixture(seconds: 2)
    defer { try? FileManager.default.removeItem(at: url) }

    let project = Project()
    let media = try await loadedTimeRemapMedia(from: url)
    project.mediaItems.append(media)

    var clip = Clip(mediaID: media.id, sourceStart: .zero,
                    duration: trTime(2), timelineStart: .zero)
    clip.speedCurve.defaultValue = 2
    clip.clampTimeRemap()
    project.videoTracks[0].clips = [clip]

    let built = try #require(try await CompositionBuilder.build(project: project))

    #expect(abs(built.duration - 1) < 0.05)
    #expect(abs(built.composition.duration.seconds - 1) < 0.05)
    #expect(built.videoComposition != nil)
}

@Test("TimeRemapping: ClipDoc round-trips speed and pitch settings")
func timeRemapClipDocRoundTrip() throws {
    var clip = Clip(mediaID: UUID(), sourceStart: trTime(1),
                    duration: trTime(6), timelineStart: trTime(2))
    clip.speedCurve = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 0.5),
            Keyframe(time: trTime(6), value: 2),
        ],
        defaultValue: 1.25)
    clip.preservePitch = false
    clip.pitchAlgorithm = .spectral

    let data = try JSONEncoder().encode(ClipDoc(clip: clip))
    let decoded = try JSONDecoder().decode(ClipDoc.self, from: data)
    let runtime = decoded.makeClip()

    #expect(runtime.speedCurve.defaultValue == 1.25)
    #expect(runtime.speedCurve.keyframes.count == 2)
    #expect(runtime.preservePitch == false)
    #expect(runtime.pitchAlgorithm == .spectral)
}

@Test("TimeRemapping: legacy ClipDoc decodes identity speed defaults")
func timeRemapLegacyClipDocDefaults() throws {
    let mediaID = UUID()
    let json = """
    {
      "mediaID": "\(mediaID.uuidString)",
      "sourceStart": { "value": 0, "timescale": 600 },
      "duration": { "value": 3000, "timescale": 600 },
      "timelineStart": { "value": 0, "timescale": 600 }
    }
    """

    let decoded = try JSONDecoder().decode(ClipDoc.self, from: Data(json.utf8))
    let runtime = decoded.makeClip()

    #expect(runtime.speedCurve.defaultValue == TimeRemapping.identitySpeed)
    #expect(runtime.speedCurve.keyframes.isEmpty)
    #expect(runtime.preservePitch)
    #expect(runtime.pitchAlgorithm == .timeDomain)
}

@Suite("Time remapping editor cache integration", .serialized)
struct TimeRemappingEditorCacheTests {
    private func cachedImage() -> CIImage {
        CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    @MainActor
    @Test("Speed edits invalidate the selected clip video cache")
    func speedEditInvalidatesVideoCache() {
        let model = EditorModel()
        let clip = Clip(mediaID: UUID(), sourceStart: .zero,
                        duration: trTime(5), timelineStart: .zero)
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id

        let key = RenderCacheKey(clipID: clip.id, effectChainHash: 1,
                                 time: .zero, renderSize: CGSize(width: 1920, height: 1080))
        RenderCache.shared.purge()
        RenderCache.shared.setImage(cachedImage(), for: key)

        model.updateSelectedClipTimeRemap { $0.speedCurve.defaultValue = 2 }
        model.commitCoalescedUndo()

        #expect(RenderCache.shared.image(for: key) == nil)
        RenderCache.shared.purge()
    }

    @MainActor
    @Test("Pitch-only edits leave the selected clip video cache intact")
    func pitchOnlyEditDoesNotInvalidateVideoCache() {
        let model = EditorModel()
        let clip = Clip(mediaID: UUID(), sourceStart: .zero,
                        duration: trTime(5), timelineStart: .zero)
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id

        let key = RenderCacheKey(clipID: clip.id, effectChainHash: 1,
                                 time: .zero, renderSize: CGSize(width: 1920, height: 1080))
        RenderCache.shared.purge()
        RenderCache.shared.setImage(cachedImage(), for: key)

        model.updateSelectedClipTimeRemap("Change Pitch", invalidateVideo: false) {
            $0.preservePitch = false
        }
        model.commitCoalescedUndo()

        #expect(RenderCache.shared.image(for: key) != nil)
        RenderCache.shared.purge()
    }
}
