import Foundation
import AVFoundation
import AVFAudio
import CoreMedia
import LocalCutCore

// MARK: - Analyzer

/// Decodes an asset to mono `Float` samples and runs the pure, deterministic
/// `BeatDetectionCore` analysis over them. The DSP, the `BeatAnalysis` model,
/// and the `.beat` cache live in `LocalCutCore`; only the AVFoundation decode
/// stays in the app target.
///
/// No mutable instance state — the actor isolation was unnecessary overhead.
/// The `analyze` method is async because it performs AVFoundation I/O.
struct BeatAnalyzer {
    private let targetSampleRate: Double = 22_050
    /// Practical decode budget: one hour covers any realistic music source and
    /// bounds memory when metadata or media is hostile/corrupt.
    private static let maxDecodeSeconds: Double = 3_600
    private var maxDecodeSamples: Int {
        Int(min(Self.maxDecodeSeconds * targetSampleRate, Double(Int.max / 2)))
    }

    func analyze(url: URL) async throws -> BeatAnalysis {
        let samples = try await decodeMonoSamples(from: url)
        return try BeatDetectionCore.analyze(samples: samples, sampleRate: targetSampleRate)
    }

    private func decodeMonoSamples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BeatAnalysisError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        // Bound the reader window from sanitized metadata before startReading so
        // a corrupt multi-day duration cannot force an unbounded decode.
        let assetDuration = try? await asset.load(.duration).sanitized
        if let assetDuration, assetDuration > .zero,
           let bounded = CMTimeRange(start: .zero, duration: assetDuration)
            .sanitized(maxDurationSeconds: Self.maxDecodeSeconds) {
            reader.timeRange = bounded
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BeatAnalysisError.readerConfigurationFailed }
        reader.add(output)
        guard reader.startReading() else {
            throw BeatAnalysisError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }

        let sampleBudget = maxDecodeSamples
        var samples: [Float] = []
        if let assetDuration, assetDuration.seconds.isFinite, assetDuration.seconds > 0 {
            // Cap the speculative reservation: a corrupt or hostile asset can
            // report an implausibly large duration, and Int(seconds * rate) would
            // otherwise trap on overflow or balloon allocation before the reader
            // has validated a single sample. One hour covers any realistic source.
            let cappedSeconds = min(assetDuration.seconds, Self.maxDecodeSeconds)
            let estimatedSamplesDouble = cappedSeconds * targetSampleRate
            let estimatedSamples = Int(min(estimatedSamplesDouble, Double(sampleBudget)))
            if estimatedSamples > 0 {
                samples.reserveCapacity(estimatedSamples)
            }
        }

        while reader.status == .reading, samples.count < sampleBudget {
            try Task.checkCancellation()
            guard let buffer = output.copyNextSampleBuffer() else { break }
            // Validate the actual sample rate matches the requested rate.
            // AVAssetReader may silently deliver audio at a different rate
            // if the codec doesn't support the requested rate.
            let format = CMSampleBufferGetFormatDescription(buffer)
            if let streamDesc = format?.audioStreamBasicDescription {
                let actualRate = streamDesc.mSampleRate
                if actualRate > 0 && abs(actualRate - targetSampleRate) > 1 {
                    throw BeatAnalysisError.readerFailed(
                        "Audio sample rate mismatch: requested \(targetSampleRate) Hz, got \(actualRate) Hz")
                }
            }
            let chunk = floats(from: buffer)
            let remaining = sampleBudget - samples.count
            if chunk.count > remaining {
                samples.append(contentsOf: chunk.prefix(remaining))
                break
            }
            samples.append(contentsOf: chunk)
        }

        if reader.status == .failed || reader.status == .cancelled {
            throw BeatAnalysisError.readerFailed(reader.error?.localizedDescription ?? "\(reader.status.rawValue)")
        }
        guard !samples.isEmpty else { throw BeatAnalysisError.insufficientSamples }
        return samples
    }

    private nonisolated func floats(from sampleBuffer: CMSampleBuffer) -> [Float] {
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return [] }

        var result: [Float] = []
        for buffer in UnsafeMutableAudioBufferListPointer(&audioBufferList) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.assumingMemoryBound(to: Float.self)
            result.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
        }
        return result
    }
}
