import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore

// MARK: - Silence Detector

/// Background actor that decodes an audio asset to mono `Float` samples and
/// runs the pure, deterministic `SilenceDetectionCore` analysis over them.
/// Mirrors the `BeatAnalyzer` pattern: AVFoundation decode in the app target,
/// pure DSP in LocalCutCore.
actor SilenceDetector {
    private let targetSampleRate: Double = 22_050

    /// Runs silence detection on the audio at the given URL.
    ///
    /// - Parameters:
    ///   - url: The source media URL.
    ///   - parameters: Detection tuning parameters.
    /// - Returns: Detected silences and proposed cuts.
    func detect(url: URL,
                parameters: SilenceDetectionParameters = SilenceDetectionParameters()
    ) async throws -> ([DetectedSilence], [ProposedCut]) {
        let samples = try await decodeMonoSamples(from: url)
        guard !samples.isEmpty else {
            throw SilenceDetectionError.emptyAudio
        }
        return SilenceDetectionCore.analyze(
            samples: samples,
            sampleRate: targetSampleRate,
            parameters: parameters)
    }

    /// Runs silence detection on pre-decoded mono float samples.
    ///
    /// - Parameters:
    ///   - samples: Mono float samples.
    ///   - sampleRate: The sample rate.
    ///   - parameters: Detection tuning parameters.
    /// - Returns: Detected silences and proposed cuts.
    nonisolated func detect(samples: [Float],
                            sampleRate: Double,
                            parameters: SilenceDetectionParameters = SilenceDetectionParameters()
    ) -> ([DetectedSilence], [ProposedCut]) {
        SilenceDetectionCore.analyze(
            samples: samples,
            sampleRate: sampleRate,
            parameters: parameters)
    }

    private func decodeMonoSamples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SilenceDetectionError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
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
        guard reader.canAdd(output) else {
            throw SilenceDetectionError.unsupportedFormat("Cannot configure audio reader.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SilenceDetectionError.unsupportedFormat(
                reader.error?.localizedDescription ?? "Unknown reader error")
        }

        var samples: [Float] = []
        let duration = try? await asset.load(.duration)
        if let duration, duration.seconds.isFinite, duration.seconds > 0 {
            let cappedSeconds = min(duration.seconds, 7200) // 2 hours cap
            let estimatedSamples = Int(cappedSeconds * targetSampleRate)
            if estimatedSamples > 0 {
                samples.reserveCapacity(estimatedSamples)
            }
        }

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let buffer = output.copyNextSampleBuffer() else { break }
            samples.append(contentsOf: floats(from: buffer))
        }

        if reader.status == .failed || reader.status == .cancelled {
            throw SilenceDetectionError.unsupportedFormat(
                reader.error?.localizedDescription ?? "\(reader.status.rawValue)")
        }

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
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return [] }

        guard let data = audioBufferList.mBuffers.mData else { return [] }
        let count = Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }
}
