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

@MainActor
private func makeTimeRemapAudioFixture(seconds: Double,
                                       sampleRate: Double = 48_000) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("time-remap-audio-\(UUID().uuidString).caf")
    try? FileManager.default.removeItem(at: url)

    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: 1,
                                     interleaved: false) else {
        throw NSError(domain: "TimeRemappingTests", code: -1)
    }
    let file = try AVAudioFile(forWriting: url,
                               settings: format.settings,
                               commonFormat: format.commonFormat,
                               interleaved: format.isInterleaved)
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "TimeRemappingTests", code: -2)
    }
    buffer.frameLength = frameCount
    try file.write(from: buffer)
    return url
}

@MainActor
private func makeTimeRemapAVFixture(seconds: Double) async throws -> URL {
    let videoURL = try await makeTimeRemapVideoFixture(seconds: seconds)
    let audioURL = try makeTimeRemapAudioFixture(seconds: seconds)
    defer {
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
    }

    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("time-remap-av-\(UUID().uuidString).mov")
    try? FileManager.default.removeItem(at: outputURL)

    let composition = AVMutableComposition()
    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)
    let duration = try await videoAsset.load(.duration)

    let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
    let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    let videoSource = try #require(videoTracks.first)
    let audioSource = try #require(audioTracks.first)

    let videoTrack = try #require(composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid))
    try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                   of: videoSource,
                                   at: .zero)

    let audioTrack = try #require(composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid))
    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                   of: audioSource,
                                   at: .zero)

    let session = try #require(AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetHighestQuality))
    try await session.export(to: outputURL, as: .mov)
    return outputURL
}

private func loadedTimeRemapMedia(from url: URL) async throws -> MediaItem {
    let item = MediaItem(url: url)
    item.duration = try await item.asset.load(.duration)
    let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
    let track = try #require(videoTracks.first)
    let audioTracks = try await item.asset.loadTracks(withMediaType: .audio)
    item.hasVideo = true
    item.hasAudio = !audioTracks.isEmpty
    item.naturalSize = try await track.load(.naturalSize)
    item.preferredTransform = try await track.load(.preferredTransform)
    return item
}

nonisolated private func sampledLuma(asset: AVAsset,
                                     videoComposition: AVVideoComposition?,
                                     at time: CMTime) async throws -> Double {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.videoComposition = videoComposition
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try await withCheckedThrowingContinuation { continuation in
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
            if let image, result == .succeeded {
                continuation.resume(returning: image)
            } else {
                continuation.resume(
                    throwing: error ?? NSError(domain: "TimeRemappingTests", code: -3))
            }
        }
    }
    return try meanLuma(image)
}

nonisolated private func meanLuma(_ image: CGImage) throws -> Double {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel,
                            width: 1,
                            height: 1,
                            bitsPerComponent: 8,
                            bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    let cgContext = try #require(context)
    cgContext.interpolationQuality = .none
    cgContext.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
}

private func audioSignature(asset: AVAsset,
                            audioMix: AVAudioMix?,
                            at time: CMTime) async throws -> (samples: Int, peak: Float) {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard !tracks.isEmpty else { return (0, 0) }

    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: time, duration: CMTime(seconds: 0.05, preferredTimescale: 600))
    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let output: AVAssetReaderOutput
    if let audioMix {
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        mixOutput.audioMix = audioMix
        output = mixOutput
    } else {
        output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
    }
    guard reader.canAdd(output) else { return (0, 0) }
    reader.add(output)
    guard reader.startReading() else { return (0, 0) }

    var sampleCount = 0
    var peak: Float = 0
    while let sampleBuffer = output.copyNextSampleBuffer(), sampleCount < 8_192 {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        var samples = [Int16](repeating: 0, count: byteCount / MemoryLayout<Int16>.size)
        let status = samples.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let destination = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer,
                                              atOffset: 0,
                                              dataLength: byteCount,
                                              destination: destination)
        }
        guard status == noErr else { continue }
        for sample in samples {
            peak = max(peak, abs(Float(sample) / Float(Int16.max)))
        }
        sampleCount += samples.count
    }
    return (sampleCount, peak)
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

@Test("TimeRemapping: bezier handles shape continuous speed evaluation")
func timeRemapBezierHandlesShapeSpeedEvaluation() {
    let linear = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 1),
            Keyframe(time: trTime(10), value: 2),
        ],
        defaultValue: 1)
    let eased = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 1,
                     outgoingHandle: KeyframeHandle(x: 0.2, y: 4)),
            Keyframe(time: trTime(10), value: 2,
                     incomingHandle: KeyframeHandle(x: 0.2, y: 4)),
        ],
        defaultValue: 1)

    let linearMid = TimeRemapping.speedValue(in: linear, at: trTime(5))
    let easedMid = TimeRemapping.speedValue(in: eased, at: trTime(5))
    let plan = TimeRemapping.segmentPlan(sourceDuration: trTime(10), speedCurve: eased)

    #expect(abs(linearMid - 1.5) < 0.01)
    #expect(easedMid > linearMid)
    #expect(plan.count == TimeRemapping.defaultSegmentsPerKeyframePair)
    #expect(plan.contains { $0.speed > 2 })
}

@Test("TimeRemapping: bezier handles subdivide even when endpoint speeds match")
func timeRemapBezierHandlesSubdivideEqualEndpointSpeeds() {
    let curve = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 1,
                     outgoingHandle: KeyframeHandle(x: 0.25, y: 3)),
            Keyframe(time: trTime(10), value: 1,
                     incomingHandle: KeyframeHandle(x: 0.25, y: 3)),
        ],
        defaultValue: 1)

    let plan = TimeRemapping.segmentPlan(sourceDuration: trTime(10), speedCurve: curve)

    #expect(plan.count == TimeRemapping.defaultSegmentsPerKeyframePair)
    #expect(plan.contains { abs($0.speed - 1) > 0.01 })
}

@Test("TimeRemapping: splitting Bezier ramps preserves handles and timing")
func timeRemapSplitPreservesBezierHandlesAndTiming() throws {
    let curve = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 1,
                     outgoingHandle: KeyframeHandle(x: 0.2, y: 4)),
            Keyframe(time: trTime(10), value: 2,
                     incomingHandle: KeyframeHandle(x: 0.2, y: 0.4)),
        ],
        defaultValue: 1)

    let originalPlan = TimeRemapping.segmentPlan(sourceDuration: trTime(10), speedCurve: curve)
    let originalCutOutput = TimeRemapping.outputOffset(forSourceOffset: trTime(5), in: originalPlan)
    let originalTotalOutput = TimeRemapping.outputDuration(for: originalPlan)
    let split = curve.splitPreservingBezier(at: trTime(5))

    let leftMid = split.left.bezierValue(at: trTime(2.5))
    let rightMid = split.right.bezierValue(at: trTime(2.5))
    #expect(abs(leftMid - curve.bezierValue(at: trTime(2.5))) < 0.01)
    #expect(abs(rightMid - curve.bezierValue(at: trTime(7.5))) < 0.01)

    #expect(split.left.keyframes.first?.outgoingHandle != nil)
    #expect(split.left.keyframes.last?.incomingHandle != nil)
    #expect(split.right.keyframes.first?.outgoingHandle != nil)
    #expect(split.right.keyframes.last?.incomingHandle != nil)

    let leftOutput = TimeRemapping.outputDuration(sourceDuration: trTime(5), speedCurve: split.left)
    let rightOutput = TimeRemapping.outputDuration(sourceDuration: trTime(5), speedCurve: split.right)
    #expect(approx(leftOutput, originalCutOutput, tolerance: 0.08))
    #expect(approx(rightOutput, originalTotalOutput - originalCutOutput, tolerance: 0.08))
}

@Test("TimeRemapping: segment boundaries snap to source sample times")
func timeRemapSegmentsSnapToSourceSamples() {
    let plan = [
        TimeRemapSegment(
            sourceRange: CMTimeRange(start: trTime(0), duration: trTime(0.51)),
            outputOffset: trTime(0),
            outputDuration: trTime(0.51),
            speed: 1),
        TimeRemapSegment(
            sourceRange: CMTimeRange(start: trTime(0.51), duration: trTime(0.49)),
            outputOffset: trTime(0.51),
            outputDuration: trTime(0.49),
            speed: 1),
    ]

    let snapped = TimeRemapping.snapSegmentPlan(
        plan,
        toSourceSampleDuration: CMTime(value: 1, timescale: 30))

    #expect(snapped.count == 2)
    #expect(approx(snapped[0].sourceRange.end, trTime(0.5), tolerance: 1.0 / 600.0))
    #expect(approx(snapped[1].sourceRange.start, snapped[0].sourceRange.end))
    #expect(approx(snapped[0].outputDuration, plan[0].outputDuration))
    #expect(approx(snapped[1].outputDuration, plan[1].outputDuration))
}

@Test("TimeRemapping: affected source range expands to neighbouring speed keyframes")
func timeRemapAffectedSourceRangeUsesAdjacentKeyframes() throws {
    let middleID = UUID()
    let before = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 1),
            Keyframe(id: middleID, time: trTime(4), value: 1),
            Keyframe(time: trTime(8), value: 1),
        ],
        defaultValue: 1)
    var after = before
    after.updateKeyframe(id: middleID, value: 2)

    let range = try #require(TimeRemapping.affectedSourceRange(
        before: before,
        after: after,
        sourceDuration: trTime(10)))

    #expect(range.start == trTime(0))
    #expect(range.end == trTime(8))
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

@MainActor
@Test("TimeRemapping: ramped A/V preview samples match exported samples")
func timeRemapPreviewExportAVParitySmoke() async throws {
    let url = try await makeTimeRemapAVFixture(seconds: 2)
    defer { try? FileManager.default.removeItem(at: url) }

    let project = Project()
    project.renderSize = CGSize(width: 64, height: 64)
    let media = try await loadedTimeRemapMedia(from: url)
    project.mediaItems.append(media)

    var videoClip = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: trTime(2), timelineStart: .zero)
    videoClip.speedCurve = Keyframed<Float>(
        keyframes: [
            Keyframe(time: .zero, value: 1,
                     outgoingHandle: KeyframeHandle(x: 0.25, y: 0.75)),
            Keyframe(time: trTime(2), value: 2,
                     incomingHandle: KeyframeHandle(x: 0.25, y: 1.75)),
        ],
        defaultValue: 1)
    var audioClip = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: trTime(2), timelineStart: .zero)
    audioClip.speedCurve = videoClip.speedCurve
    project.videoTracks[0].clips = [videoClip]
    project.audioTracks[0].clips = [audioClip]

    let built = try #require(try await CompositionBuilder.build(project: project))
    let videoComposition = try #require(built.videoComposition)
    let audioMix = try #require(built.audioMix)

    let exportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("time-remap-export-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: exportURL) }

    let session = try #require(AVAssetExportSession(
        asset: built.composition,
        presetName: AVAssetExportPresetHighestQuality))
    session.videoComposition = videoComposition
    session.audioMix = audioMix
    try await session.export(to: exportURL, as: .mov)

    let exported = AVURLAsset(url: exportURL)
    let sampleTimes = [trTime(0.1), trTime(min(0.85, max(0.15, built.duration - 0.1)))]
    for sampleTime in sampleTimes {
        let previewLuma = try await sampledLuma(
            asset: built.composition,
            videoComposition: videoComposition,
            at: sampleTime)
        let exportedLuma = try await sampledLuma(asset: exported,
                                                 videoComposition: nil,
                                                 at: sampleTime)
        #expect(abs(previewLuma - exportedLuma) <= 3.0)

        let previewAudio = try await audioSignature(asset: built.composition,
                                                    audioMix: audioMix,
                                                    at: sampleTime)
        let exportedAudio = try await audioSignature(asset: exported,
                                                     audioMix: nil,
                                                     at: sampleTime)
        #expect(previewAudio.samples > 0)
        #expect(exportedAudio.samples > 0)
        #expect(abs(previewAudio.peak - exportedAudio.peak) < 0.001)
    }
}

@Test("TimeRemapping: ClipDoc round-trips speed and pitch settings")
func timeRemapClipDocRoundTrip() throws {
    var clip = Clip(mediaID: UUID(), sourceStart: trTime(1),
                    duration: trTime(6), timelineStart: trTime(2))
    clip.speedCurve = Keyframed<Float>(
        keyframes: [
            Keyframe(time: trTime(0), value: 0.5,
                     outgoingHandle: KeyframeHandle(x: 0.25, y: 1.5)),
            Keyframe(time: trTime(6), value: 2,
                     incomingHandle: KeyframeHandle(x: 0.25, y: 1.25)),
        ],
        defaultValue: 1.25)
    clip.preservePitch = false
    clip.pitchAlgorithm = .spectral

    let data = try JSONEncoder().encode(ClipDoc(clip: clip))
    let decoded = try JSONDecoder().decode(ClipDoc.self, from: data)
    let runtime = decoded.makeClip()

    #expect(runtime.speedCurve.defaultValue == 1.25)
    #expect(runtime.speedCurve.keyframes.count == 2)
    #expect(runtime.speedCurve.keyframes[0].outgoingHandle == KeyframeHandle(x: 0.25, y: 1.5))
    #expect(runtime.speedCurve.keyframes[1].incomingHandle == KeyframeHandle(x: 0.25, y: 1.25))
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
    @Test("Speed keyframe edits keep cache entries outside the affected source range")
    func speedKeyframeEditInvalidatesOnlyAffectedRange() {
        let model = EditorModel()
        var clip = Clip(mediaID: UUID(), sourceStart: .zero,
                        duration: trTime(6), timelineStart: .zero)
        let middleID = UUID()
        clip.speedCurve = Keyframed<Float>(
            keyframes: [
                Keyframe(time: .zero, value: 1),
                Keyframe(id: middleID, time: trTime(2), value: 1),
                Keyframe(time: trTime(4), value: 1),
            ],
            defaultValue: 1)
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id

        let affected = RenderCacheKey(clipID: clip.id, effectChainHash: 1,
                                      time: trTime(1), renderSize: CGSize(width: 1920, height: 1080))
        let unaffected = RenderCacheKey(clipID: clip.id, effectChainHash: 1,
                                        time: trTime(5), renderSize: CGSize(width: 1920, height: 1080))
        RenderCache.shared.purge()
        RenderCache.shared.setImage(cachedImage(), for: affected)
        RenderCache.shared.setImage(cachedImage(), for: unaffected)

        model.updateSelectedClipTimeRemap {
            $0.speedCurve.updateKeyframe(id: middleID, value: 2)
        }
        model.commitCoalescedUndo()

        #expect(RenderCache.shared.image(for: affected) == nil)
        #expect(RenderCache.shared.image(for: unaffected) != nil)
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

// MARK: - Speed keyframe rebasing under edits

/// Speed keyframe times are clip-source-relative, so any edit that moves a
/// clip's source origin or shortens its source span must rebase/filter those
/// keyframes — otherwise the ramp drifts off the media frames it was authored
/// against. These cover split, left-trim, and right-trim.
@MainActor
@Suite("Time remapping keyframe rebasing")
struct TimeRemappingKeyframeRebaseTests {
    private func constantSpeedCurve(_ keyframeSeconds: [Double]) -> Keyframed<Float> {
        Keyframed<Float>(
            keyframes: keyframeSeconds.map {
                Keyframe<Float>(time: trTime($0), value: 1)
            },
            defaultValue: 1)
    }

    @Test("Split partitions speed keyframes and inserts a cut boundary on each half")
    func splitRebasesSpeedKeyframes() throws {
        let model = EditorModel()
        var clip = Clip(mediaID: UUID(), sourceStart: .zero,
                        duration: trTime(8), timelineStart: .zero)
        // 1× everywhere so the output split point equals the source split point.
        clip.speedCurve = constantSpeedCurve([1, 7])
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id

        model.currentTime = 4.0
        model.splitSelectedClipAtPlayhead()

        let clips = model.project.videoTracks[0].clips
        #expect(clips.count == 2)
        // Cut at source 4 s: left keeps the 1 s keyframe and gains a boundary
        // keyframe at the cut (4 s) so the ramp shape is preserved.
        #expect(clips[0].speedCurve.keyframes.map { $0.time } == [trTime(1), trTime(4)])
        // Right half rebases to its own origin: a boundary at 0 plus 7 s − 4 s = 3 s.
        #expect(clips[1].sourceStart == trTime(4))
        #expect(clips[1].speedCurve.keyframes.map { $0.time } == [trTime(0), trTime(3)])
    }

    @Test("Split preserves the ramp so halves stay adjacent and total length holds")
    func splitPreservesRampBoundary() {
        let model = EditorModel()
        var clip = Clip(mediaID: UUID(), sourceStart: .zero,
                        duration: trTime(10), timelineStart: .zero)
        // A genuine ramp: 1× at the head accelerating to 3× at the tail. Filtering
        // keyframes without a boundary would flatten one side and detach the cut.
        clip.speedCurve = Keyframed<Float>(
            keyframes: [Keyframe<Float>(time: trTime(0), value: 1),
                        Keyframe<Float>(time: trTime(10), value: 3)],
            defaultValue: 1)
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id
        let originalOutput = clip.outputDuration

        model.currentTime = originalOutput.seconds * 0.5
        model.splitSelectedClipAtPlayhead()

        let clips = model.project.videoTracks[0].clips
        #expect(clips.count == 2)
        // The boundary keyframe keeps the left half's ramp intact, so it still
        // ends at the playhead where the right half begins. A flattened ramp
        // (the bug) would leave the left half ~2 s short of the cut; the tolerance
        // here only absorbs the piecewise-constant plan's re-discretisation, which
        // is an order of magnitude smaller.
        #expect(approx(clips[0].timelineEnd, clips[1].timelineStart, tolerance: 0.1))
        // No meaningful output time is gained or lost across the cut.
        #expect(approx(clips[0].outputDuration + clips[1].outputDuration,
                       originalOutput, tolerance: 0.1))
    }

    @Test("Trim left earlier reveals trimmed-in media and keeps the right edge fixed")
    func trimLeftEarlierRevealsMedia() {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        // Right half of a split: 2 s of source already trimmed off the head.
        let clip = Clip(mediaID: media.id, sourceStart: trTime(2),
                        duration: trTime(4), timelineStart: trTime(5))
        model.project.videoTracks[0].clips = [clip]
        let originalEnd = clip.timelineEnd

        model.trimClip(id: clip.id, edge: .left, to: trTime(3))

        let trimmed = model.project.videoTracks[0].clips[0]
        // Dragging the head 2 s earlier reveals the 2 s of trimmed-in source.
        #expect(trimmed.timelineStart == trTime(3))
        #expect(trimmed.sourceStart == .zero)
        #expect(trimmed.duration == trTime(6))
        // The right edge must not move — only the head was dragged.
        #expect(approx(trimmed.timelineEnd, originalEnd, tolerance: 0.005))
    }

    @Test("Slowing a clip ripples its downstream neighbour")
    func speedChangeRipplesDownstream() {
        let model = EditorModel()
        let a = Clip(mediaID: UUID(), sourceStart: .zero, duration: trTime(4), timelineStart: .zero)
        let b = Clip(mediaID: UUID(), sourceStart: .zero, duration: trTime(4), timelineStart: trTime(4))
        model.project.videoTracks[0].clips = [a, b]
        model.selectedClipID = a.id

        // 0.5× doubles A's output length from 4 s to 8 s, so B must ripple +4 s.
        model.updateSelectedClipTimeRemap { $0.speedCurve.defaultValue = 0.5 }

        let clips = model.project.videoTracks[0].clips
        let aNow = clips.first { $0.id == a.id }!
        let bNow = clips.first { $0.id == b.id }!
        #expect(approx(aNow.outputDuration, trTime(8), tolerance: 0.01))
        #expect(approx(bNow.timelineStart, trTime(8), tolerance: 0.01))
    }

    @Test("Retiming one half of a linked A/V pair retimes the other")
    func linkedAudioVideoRetimeTogether() {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        media.hasAudio = true
        model.project.mediaItems.append(media)

        // Same media + range placed on V1 and A1 — a linked pair.
        let videoClip = Clip(mediaID: media.id, sourceStart: .zero,
                             duration: trTime(10), timelineStart: .zero)
        let audioClip = Clip(mediaID: media.id, sourceStart: .zero,
                             duration: trTime(10), timelineStart: .zero)
        model.project.videoTracks[0].clips = [videoClip]
        model.project.audioTracks[0].clips = [audioClip]
        model.selectedClipID = videoClip.id

        model.updateSelectedClipTimeRemap { $0.speedCurve.defaultValue = 2 }

        // The audio clip must follow so it doesn't drift past the picture.
        #expect(model.project.audioTracks[0].clips[0].speedCurve.defaultValue == 2)
    }

    @Test("Linked A/V speed keyframes update and remove by source time")
    func linkedAudioVideoSpeedKeyframesSyncByTime() {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        media.hasAudio = true
        model.project.mediaItems.append(media)

        let videoClip = Clip(mediaID: media.id, sourceStart: .zero,
                             duration: trTime(10), timelineStart: .zero)
        let audioClip = Clip(mediaID: media.id, sourceStart: .zero,
                             duration: trTime(10), timelineStart: .zero)
        model.project.videoTracks[0].clips = [videoClip]
        model.project.audioTracks[0].clips = [audioClip]
        model.selectedClipID = videoClip.id

        model.currentTime = 2
        model.addOrUpdateSelectedClipSpeedKeyframe()
        model.updateSelectedClipTimeRemap { $0.speedCurve.defaultValue = 3 }
        model.commitCoalescedUndo()

        model.currentTime = 2
        model.addOrUpdateSelectedClipSpeedKeyframe()

        let videoKeyframes = model.project.videoTracks[0].clips[0].speedCurve.keyframes
        let audioKeyframes = model.project.audioTracks[0].clips[0].speedCurve.keyframes
        #expect(videoKeyframes.map(\.time) == [trTime(2)])
        #expect(audioKeyframes.map(\.time) == [trTime(2)])
        #expect(videoKeyframes.map(\.value) == [3])
        #expect(audioKeyframes.map(\.value) == [3])

        let updatedVideo = model.project.videoTracks[0].clips[0]
        model.currentTime = updatedVideo.outputOffset(forSourceOffset: trTime(2)).seconds
        model.removeSelectedClipSpeedKeyframe()

        #expect(model.project.videoTracks[0].clips[0].speedCurve.keyframes.isEmpty)
        #expect(model.project.audioTracks[0].clips[0].speedCurve.keyframes.isEmpty)
    }

    @Test("Look strength keyframes author in source-local time under retiming")
    func lookStrengthKeyframesUseSourceLocalTime() {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        var clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: trTime(10), timelineStart: .zero)
        clip.speedCurve = Keyframed<Float>(defaultValue: 2)
        clip.effects = [.grain(GrainEffect(amount: Keyframed(defaultValue: 0.4)))]
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id
        model.currentTime = 1.5

        model.addOrUpdateLookStrengthKeyframe(.grain)

        let keyframes = model.project.videoTracks[0].clips[0].effects
            .compactMap(\.lookStrength)
            .first?
            .keyframes ?? []
        #expect(keyframes.map(\.time) == [trTime(3)])
        #expect(keyframes.map(\.value) == [0.4])
    }

    @Test("Speed keyframe seek uses effective time after transition ripple")
    func speedKeyframeSeekUsesEffectiveTime() {
        let model = EditorModel()
        let media = UUID()
        let a = Clip(mediaID: media, sourceStart: .zero, duration: trTime(5), timelineStart: .zero)
        var b = Clip(mediaID: media, sourceStart: .zero, duration: trTime(5), timelineStart: trTime(5))
        b.transition = Transition(duration: trTime(1))
        b.speedCurve = Keyframed<Float>(
            keyframes: [Keyframe<Float>(time: trTime(1), value: 1),
                        Keyframe<Float>(time: trTime(3), value: 1)],
            defaultValue: 1)
        model.project.videoTracks[0].clips = [a, b]
        model.selectedClipID = b.id
        model.totalDuration = model.project.duration.seconds

        model.currentTime = 4.2
        model.seekToNextSelectedClipSpeedKeyframe()

        #expect(approx(trTime(model.currentTime), trTime(5)))
    }

    @Test("Moving a retimed clip resolves collisions using output duration")
    func moveRetimedClipUsesOutputDurationForOverlap() {
        let model = EditorModel()
        var retimed = Clip(mediaID: UUID(), sourceStart: .zero,
                           duration: trTime(4), timelineStart: .zero)
        retimed.speedCurve.defaultValue = 0.5
        let blocker = Clip(mediaID: UUID(), sourceStart: .zero,
                           duration: trTime(2), timelineStart: trTime(9))
        let track = model.project.videoTracks[0]
        track.clips = [retimed, blocker]

        model.moveClip(id: retimed.id, toTrack: track.id, start: trTime(2))

        let moved = track.clips.first { $0.id == retimed.id }!
        #expect(approx(moved.timelineStart, trTime(1)))
        #expect(approx(moved.timelineEnd, blocker.timelineStart))
    }

    @Test("Trim rebases skin-smooth strength keyframes alongside speed")
    func trimRebasesSkinSmoothKeyframes() {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        var smooth = SkinSmoothEffect()
        smooth.strength = Keyframed<Float>(
            keyframes: [Keyframe<Float>(time: trTime(2), value: 0.5),
                        Keyframe<Float>(time: trTime(5), value: 0.8)],
            defaultValue: 0)
        var clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: trTime(10), timelineStart: .zero)
        clip.effects = [.skinSmooth(smooth)]
        model.project.videoTracks[0].clips = [clip]

        model.trimClip(id: clip.id, edge: .left, to: trTime(3))

        let trimmed = model.project.videoTracks[0].clips[0]
        guard case .skinSmooth(let s) = trimmed.effects.first(where: {
            if case .skinSmooth = $0 { return true }; return false
        }) else {
            #expect(Bool(false), "skin-smooth effect missing")
            return
        }
        // Origin advanced 3 s: an evaluated boundary pins the trim frame at the
        // new origin, and the 5 s keyframe becomes 2 s.
        #expect(s.strength.keyframes.map { $0.time } == [trTime(0), trTime(2)])
    }

    @Test("Trim left rebases speed keyframes onto the new source origin")
    func trimLeftRebasesSpeedKeyframes() throws {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        var clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: trTime(10), timelineStart: .zero)
        clip.speedCurve = constantSpeedCurve([2, 5])
        model.project.videoTracks[0].clips = [clip]

        model.trimClip(id: clip.id, edge: .left, to: trTime(3))

        let trimmed = model.project.videoTracks[0].clips[0]
        #expect(trimmed.sourceStart == trTime(3))
        // Origin advanced 3 s: an evaluated boundary pins the trim frame at the
        // new origin, and the 5 s keyframe becomes 2 s.
        #expect(trimmed.speedCurve.keyframes.map { $0.time } == [trTime(0), trTime(2)])
    }

    @Test("Trim left inside a speed ramp preserves the evaluated boundary value")
    func trimLeftInsideRampPreservesBoundaryValue() throws {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        var clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: trTime(10), timelineStart: .zero)
        clip.speedCurve = Keyframed<Float>(
            keyframes: [Keyframe<Float>(time: .zero, value: 1),
                        Keyframe<Float>(time: trTime(10), value: 3)],
            defaultValue: 1)
        let trimTime = clip.outputOffset(forSourceOffset: trTime(5))
        model.project.videoTracks[0].clips = [clip]

        model.trimClip(id: clip.id, edge: .left, to: trimTime)

        let trimmed = model.project.videoTracks[0].clips[0]
        let first = try #require(trimmed.speedCurve.keyframes.first)
        #expect(first.time == .zero)
        #expect(abs(first.value - 2) < 0.01)
    }

    @Test("Trim right drops speed keyframes past the new source duration")
    func trimRightDropsStaleSpeedKeyframes() throws {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = trTime(10)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        var clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: trTime(10), timelineStart: .zero)
        clip.speedCurve = constantSpeedCurve([2, 8])
        model.project.videoTracks[0].clips = [clip]

        model.trimClip(id: clip.id, edge: .right, to: trTime(5))

        let trimmed = model.project.videoTracks[0].clips[0]
        #expect(trimmed.duration == trTime(5))
        // Source span shrank to 5 s, so the 8 s keyframe no longer fits.
        // A boundary keyframe is inserted at the new duration to preserve the
        // ramp shape at the trim point.
        #expect(trimmed.speedCurve.keyframes.map { $0.time } == [trTime(2), trTime(5)])
        // Boundary value matches the interpolated value at the trim point.
        #expect(trimmed.speedCurve.keyframes.last?.value == 1)
    }
}
