import Testing
import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - Video Fixture

/// Writes a short solid-colour H.264 `.mov` to a temp file and returns its URL.
///
/// - Parameters:
///   - seconds: Duration of the generated clip.
///   - fps: Frames per second (default 30).
///   - size: Frame dimensions (default 64x64). Odd dimensions are rounded down
///     to the nearest even number because H.264 rejects odd widths/heights.
///   - color: Byte value used to fill every pixel (mid-grey `0x80` by default).
///   - directory: Directory to write into (defaults to the system temp directory).
func makeVideoFixture(
    seconds: Double,
    fps: Int32 = 30,
    size: CGSize = CGSize(width: 64, height: 64),
    color: UInt8 = 0x80,
    in directory: URL = FileManager.default.temporaryDirectory
) async throws -> URL {
    let url = directory.appendingPathComponent("test-fixture-\(UUID().uuidString).mov")
    try? FileManager.default.removeItem(at: url)
    var success = false
    defer { if !success { try? FileManager.default.removeItem(at: url) } }

    // H.264 rejects odd dimensions; mask the low bit off after rounding.
    let w = max(2, Int(size.width.rounded()) & ~1)
    let h = max(2, Int(size.height.rounded()) & ~1)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: w,
        AVVideoHeightKey: h,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    guard let pool = adaptor.pixelBufferPool else {
        throw NSError(domain: "TestFixtures", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "pixelBufferPool was nil"])
    }

    let frameCount = Int(seconds * Double(fps))
    for frame in 0..<frameCount {
        let readyDeadline = ContinuousClock.now + .seconds(5)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error ?? NSError(domain: "TestFixtures", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter not in .writing status"])
            }
            guard ContinuousClock.now < readyDeadline else {
                throw NSError(domain: "TestFixtures", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter input never became ready (5s timeout)"])
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "TestFixtures", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPoolCreatePixelBuffer failed (\(status))"])
        }
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw NSError(domain: "TestFixtures", code: Int(lockStatus),
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferLockBaseAddress failed (\(lockStatus))"])
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw NSError(domain: "TestFixtures", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferGetBaseAddress returned nil at frame \(frame)"])
        }
        let actualHeight = CVPixelBufferGetHeight(buffer)
        memset(baseAddress, Int32(color), CVPixelBufferGetBytesPerRow(buffer) * actualHeight)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)
        ) else {
            throw writer.error ?? NSError(domain: "TestFixtures", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "adaptor.append failed at frame \(frame)"])
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    success = true
    return url
}

// MARK: - Pixel Buffer

/// Creates a `CVPixelBuffer` filled with a solid RGB colour (32ARGB format).
///
/// - Parameters:
///   - width: Buffer width in pixels.
///   - height: Buffer height in pixels.
///   - r, g, b: Channel values (0-255). The alpha channel is always 255.
func makePixelBuffer(
    width: Int,
    height: Int,
    r: UInt8 = 0x80,
    g: UInt8 = 0x80,
    b: UInt8 = 0x80
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32ARGB,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        throw NSError(domain: "TestFixtures", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed (\(status))"])
    }

    let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
    guard lockStatus == kCVReturnSuccess else {
        throw NSError(domain: "TestFixtures", code: Int(lockStatus),
                      userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferLockBaseAddress failed (\(lockStatus))"])
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
        throw NSError(domain: "TestFixtures", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferGetBaseAddress returned nil"])
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

    // Fill the buffer with a solid 32-bit ARGB pattern using typed pointer
    // initialization — one call per row instead of width * copyMemory calls.
    // Alpha is always 0xFF for opaque test fixtures.
    let argb = UInt32(0xFF000000) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    let typedBase = baseAddress.assumingMemoryBound(to: UInt32.self)
    for row in 0..<height {
        let rowStart = typedBase.advanced(by: row * (bytesPerRow / MemoryLayout<UInt32>.stride))
        rowStart.initialize(repeating: argb, count: width)
    }
    return buffer
}

// MARK: - Loaded Media

/// Loads common properties from a video URL into a `MediaItem`.
///
/// Populates `duration`, `hasVideo`, `naturalSize`, and `preferredTransform`.
func loadedMedia(from url: URL) async throws -> MediaItem {
    let item = MediaItem(url: url)
    // Load duration and track lists in parallel — they are independent.
    async let durationLoad = item.asset.load(.duration)
    async let videoTrackLoad = item.asset.loadTracks(withMediaType: .video)
    async let audioTrackLoad = item.asset.loadTracks(withMediaType: .audio)

    item.duration = try await durationLoad.sanitized
    let videoTracks = try await videoTrackLoad
    let audioTracks = try await audioTrackLoad
    let track = try #require(videoTracks.first)
    item.hasVideo = !videoTracks.isEmpty
    item.hasAudio = !audioTracks.isEmpty

    // naturalSize and preferredTransform are independent of each other.
    let (size, transform) = try await (track.load(.naturalSize), track.load(.preferredTransform))
    item.naturalSize = size.sanitized
    item.preferredTransform = transform.sanitized
    return item
}

// MARK: - Combined A/V Fixture

/// Creates a single `.mov` containing both video and audio tracks by writing
/// separate fixtures and merging them through `AVAssetExportSession`.
///
/// - Parameters:
///   - seconds: Duration of the generated clip.
///   - fps: Video frames per second (default 30).
///   - size: Video frame dimensions (default 64x64).
///   - directory: Directory to write into (defaults to the system temp directory).
/// - Returns: URL of the merged `.mov` file.
func makeAVFixture(
    seconds: Double,
    fps: Int32 = 30,
    size: CGSize = CGSize(width: 64, height: 64),
    in directory: URL = FileManager.default.temporaryDirectory
) async throws -> URL {
    // Register each cleanup immediately after creation so a later fixture
    // failure cannot strand the first file in the temporary directory.
    let videoURL = try await makeVideoFixture(seconds: seconds, fps: fps, size: size, in: directory)
    defer { try? FileManager.default.removeItem(at: videoURL) }
    let audioURL = try makeAudioFixture(seconds: seconds, in: directory)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let outputURL = directory.appendingPathComponent("av-fixture-\(UUID().uuidString).mov")
    try? FileManager.default.removeItem(at: outputURL)
    var outputSuccess = false
    defer { if !outputSuccess { try? FileManager.default.removeItem(at: outputURL) } }

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
    outputSuccess = true
    return outputURL
}

// MARK: - Audio Fixture

/// Writes a short mono CAF (Core Audio Format) file filled with silence and
/// returns its URL.  Uses `AVAudioFile` so we don't have to plumb CoreMedia
/// sample buffers by hand.
///
/// - Parameters:
///   - seconds: Duration of the generated audio.
///   - sampleRate: Sample rate in Hz (default 48 000).
///   - directory: Directory to write into (defaults to the system temp directory).
func makeAudioFixture(
    seconds: Double,
    sampleRate: Double = 48_000,
    in directory: URL = FileManager.default.temporaryDirectory
) throws -> URL {
    let url = directory.appendingPathComponent("audio-fixture-\(UUID().uuidString).caf")
    try? FileManager.default.removeItem(at: url)
    var success = false
    defer { if !success { try? FileManager.default.removeItem(at: url) } }

    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else {
        throw NSError(domain: "TestFixtures", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "AVAudioFormat creation failed for \(sampleRate) Hz"])
    }
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "TestFixtures", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "AVAudioPCMBuffer creation failed for \(frameCount) frames"])
    }
    buffer.frameLength = frameCount
    // Default-allocated channelData is zero — true silence.
    try file.write(from: buffer)
    success = true
    return url
}
