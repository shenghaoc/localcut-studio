import Testing
import AVFoundation
import CoreMedia
@testable import LocalCut_Studio

// MARK: - PCM sample type

/// Discriminated union over the two PCM sample types used in audio tests,
/// avoiding the need for three near-identical buffer-creation functions.
enum PCMSampleType {
    case int16([Int16])
    case float32([Float])
}

// MARK: - Generic PCM sample-buffer factory

/// Creates a `CMSampleBuffer` containing interleaved PCM audio data.
///
/// Replaces the three private helpers that previously lived in
/// `AudioMasterBusTests.swift` (`makePCMInt16SampleBuffer`,
/// `makeFragmentedPCMInt16SampleBuffer`, `makePCMFloat32SampleBuffer`).
///
/// - Parameters:
///   - sampleType: An enum carrying either `[Int16]` or `[Float]` samples.
///   - channels: Number of interleaved audio channels.
///   - sampleRate: Sample rate in Hz (default 48 000).
///   - fragmented: When `true`, the backing `CMBlockBuffer` is built from two
///     appended memory blocks to exercise the fragmented-buffer path in audio
///     processors. Default `false`.
/// - Returns: A ready-to-use `CMSampleBuffer`.
func makePCMSampleBuffer(
    sampleType: PCMSampleType,
    channels: Int,
    sampleRate: Int = 48_000,
    fragmented: Bool = false
) throws -> CMSampleBuffer {
    guard channels > 0 else {
        throw NSError(domain: "AudioTestHelpers", code: -2)
    }

    // -- Determine format flags and element size from the sample type --
    let isFloat: Bool
    let bitsPerChannel: Int
    let bytesPerElement: Int

    switch sampleType {
    case .int16:
        isFloat = false
        bitsPerChannel = 16
        bytesPerElement = MemoryLayout<Int16>.size
    case .float32:
        isFloat = true
        bitsPerChannel = 32
        bytesPerElement = MemoryLayout<Float>.size
    }

    let formatFlags: AudioFormatFlags = isFloat
        ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
    let bytesPerFrame = bytesPerElement * channels

    // -- AudioStreamBasicDescription --
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Float64(sampleRate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: formatFlags,
        mBytesPerPacket: UInt32(bytesPerFrame),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(bytesPerFrame),
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: UInt32(bitsPerChannel),
        mReserved: 0
    )

    // -- CMAudioFormatDescription --
    var formatDescription: CMAudioFormatDescription?
    let fmtStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard fmtStatus == noErr, let formatDescription else {
        throw NSError(domain: "AudioTestHelpers", code: Int(fmtStatus))
    }

    // -- Raw sample bytes --
    let sampleData: [UInt8] = switch sampleType {
    case .int16(let samples):
        samples.withUnsafeBytes { Array($0) }
    case .float32(let samples):
        samples.withUnsafeBytes { Array($0) }
    }

    let byteCount = sampleData.count

    // -- CMBlockBuffer (contiguous or fragmented) --
    var blockBuffer: CMBlockBuffer?
    if fragmented {
        let firstHalf = byteCount / 2
        let secondHalf = byteCount - firstHalf

        let emptyStatus = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 2,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard emptyStatus == noErr, let blockBuffer else {
            throw NSError(domain: "AudioTestHelpers", code: Int(emptyStatus))
        }

        let app1 = CMBlockBufferAppendMemoryBlock(
            blockBuffer,
            memoryBlock: nil,
            length: firstHalf,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: firstHalf,
            flags: 0
        )
        guard app1 == noErr else {
            throw NSError(domain: "AudioTestHelpers", code: Int(app1))
        }

        let app2 = CMBlockBufferAppendMemoryBlock(
            blockBuffer,
            memoryBlock: nil,
            length: secondHalf,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: secondHalf,
            flags: 0
        )
        guard app2 == noErr else {
            throw NSError(domain: "AudioTestHelpers", code: Int(app2))
        }
    } else {
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else {
            throw NSError(domain: "AudioTestHelpers", code: Int(createStatus))
        }
    }

    // -- Copy sample bytes into the block buffer --
    guard let blockBuffer else {
        throw NSError(domain: "AudioTestHelpers", code: -1)
    }
    if byteCount > 0 {
        let replaceStatus = sampleData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return noErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == noErr else {
            throw NSError(domain: "AudioTestHelpers", code: Int(replaceStatus))
        }
    }

    // -- CMSampleBuffer --
    let sampleCount = byteCount / (bytesPerElement * channels)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(sampleRate)),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: sampleCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw NSError(domain: "AudioTestHelpers", code: Int(sampleStatus))
    }
    return sampleBuffer
}

// MARK: - Convenience wrappers for existing call-sites

/// Creates a contiguous Int16 PCM sample buffer.
func makePCMInt16SampleBuffer(
    samples: [Int16],
    channels: Int,
    sampleRate: Int = 48_000
) throws -> CMSampleBuffer {
    try makePCMSampleBuffer(
        sampleType: .int16(samples),
        channels: channels,
        sampleRate: sampleRate
    )
}

/// Creates a fragmented Int16 PCM sample buffer (two appended memory blocks).
func makeFragmentedPCMInt16SampleBuffer(
    samples: [Int16],
    channels: Int,
    sampleRate: Int = 48_000
) throws -> CMSampleBuffer {
    try makePCMSampleBuffer(
        sampleType: .int16(samples),
        channels: channels,
        sampleRate: sampleRate,
        fragmented: true
    )
}

/// Creates a contiguous Float32 PCM sample buffer.
func makePCMFloat32SampleBuffer(
    samples: [Float],
    channels: Int,
    sampleRate: Int = 48_000
) throws -> CMSampleBuffer {
    try makePCMSampleBuffer(
        sampleType: .float32(samples),
        channels: channels,
        sampleRate: sampleRate
    )
}

// MARK: - CMTime helper

/// Shorthand for creating a `CMTime` from seconds at 600 timescale (29.97 fps
/// friendly).
nonisolated func cm(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

// MARK: - Audio media loading

/// Creates a `MediaItem` from a file URL, loads its duration, and verifies it
/// has at least one audio track. Callers can then attach video tracks or
/// configure the item further.
@MainActor
func loadAudioMedia(from url: URL) async throws -> MediaItem {
    let item = MediaItem(url: url)
    item.duration = try await item.asset.load(.duration)
    let audioTracks = try await item.asset.loadTracks(withMediaType: .audio)
    _ = try #require(audioTracks.first)
    item.hasAudio = true
    return item
}

// MARK: - Render queue settle helper

/// Polls a ``RenderQueue`` until the expected number of jobs are present and
/// all have reached a terminal state, or the timeout expires.
@MainActor
func waitForRenderQueueToSettle(
    _ queue: RenderQueue,
    expectedCount: Int,
    timeout: TimeInterval
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if queue.jobs.count == expectedCount,
           !queue.isRunning,
           queue.jobs.allSatisfy(\.isTerminal) {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Render queue did not settle before timeout")
}
