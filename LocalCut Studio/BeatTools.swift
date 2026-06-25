import Foundation
import AVFoundation
import AVFAudio
import CoreMedia
import LocalCutCore

// MARK: - Beat analysis model

/// Source-relative beat analysis for one audio asset.
nonisolated struct BeatAnalysis: Equatable, Codable, Sendable {
    var tempoBPM: Double
    var beatTimes: [CMTime]
    var confidence: Float

    init(tempoBPM: Double, beatTimes: [CMTime], confidence: Float) {
        self.tempoBPM = tempoBPM
        self.beatTimes = beatTimes
        self.confidence = confidence
    }
    private enum CodingKeys: String, CodingKey { case tempoBPM, beatTimes, confidence }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tempoBPM = try c.decode(Double.self, forKey: .tempoBPM)
        beatTimes = try c.decode([CMTimeCode].self, forKey: .beatTimes).map(\.cmTime)
        confidence = try c.decode(Float.self, forKey: .confidence)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tempoBPM, forKey: .tempoBPM)
        try c.encode(beatTimes.map(CMTimeCode.init), forKey: .beatTimes)
        try c.encode(confidence, forKey: .confidence)
    }
}

/// A projected, timeline-relative beat used for ruler drawing and snapping.
nonisolated struct ProjectedBeatMarker: Identifiable, Hashable, Sendable {
    let id: String
    var time: CMTime
}

// MARK: - Cache

nonisolated enum BeatAnalysisCache {
    private static let magic = Data([0x4C, 0x43, 0x42, 0x54]) // "LCBT"
    private static let version: UInt32 = 1
    static let fileExtension = "beat"

    static func fileName(for key: String) -> String {
        "\(key).\(fileExtension)"
    }

    static func url(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(for: key))
    }

    static func read(key: String, in directory: URL) throws -> BeatAnalysis? {
        let fileURL = url(for: key, in: directory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try decode(data)
    }

    static func write(_ analysis: BeatAnalysis, key: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encode(analysis)
        try data.write(to: url(for: key, in: directory), options: .atomic)
    }

    static func encode(_ analysis: BeatAnalysis) throws -> Data {
        var data = Data()
        data.append(magic)
        appendUInt32(version, to: &data)
        let payload = try JSONEncoder().encode(analysis)
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) throws -> BeatAnalysis? {
        guard data.count >= magic.count + MemoryLayout<UInt32>.size,
              data.prefix(magic.count) == magic else { return nil }
        let encodedVersion = readUInt32(from: data, offset: magic.count)
        guard encodedVersion == version else { return nil }
        let payloadStart = magic.count + MemoryLayout<UInt32>.size
        let payload = data[payloadStart..<data.count]
        return try JSONDecoder().decode(BeatAnalysis.self, from: payload)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            UInt32(littleEndian: rawBuffer.load(fromByteOffset: offset, as: UInt32.self))
        }
    }
}

// MARK: - Analyzer

enum BeatAnalysisError: LocalizedError {
    case noAudioTrack
    case readerConfigurationFailed
    case readerFailed(String)
    case insufficientSamples

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "No audio track was found."
        case .readerConfigurationFailed:
            return "Could not configure the audio reader."
        case .readerFailed(let reason):
            return "Audio decode failed: \(reason)"
        case .insufficientSamples:
            return "The audio is too short to analyse."
        }
    }
}

/// Background actor that decodes an asset and runs deterministic beat analysis.
actor BeatAnalyzer {
    private let targetSampleRate: Double = 22_050

    func analyze(url: URL) async throws -> BeatAnalysis {
        let samples = try await decodeMonoSamples(from: url)
        return try analyze(samples: samples, sampleRate: targetSampleRate)
    }

    func analyze(samples: [Float], sampleRate: Double) throws -> BeatAnalysis {
        try BeatDetectionCore.analyze(samples: samples, sampleRate: sampleRate)
    }

    private func decodeMonoSamples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BeatAnalysisError.noAudioTrack
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
        guard reader.canAdd(output) else { throw BeatAnalysisError.readerConfigurationFailed }
        reader.add(output)
        guard reader.startReading() else {
            throw BeatAnalysisError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }

        var samples: [Float] = []
        let duration = try? await asset.load(.duration)
        if let duration, duration.seconds.isFinite {
            let estimatedSamples = Int(duration.seconds * targetSampleRate)
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

// MARK: - Detection core

nonisolated enum BeatDetectionCore {
    static let defaultFrameSize = 1024
    static let defaultHopSize = 512
    static let emittedTimescale: CMTimeScale = 600

    static func analyze(samples: [Float], sampleRate: Double) throws -> BeatAnalysis {
        guard samples.count >= defaultFrameSize, sampleRate > 0 else {
            throw BeatAnalysisError.insufficientSamples
        }
        let envelope = onsetEnvelope(samples: samples, frameSize: defaultFrameSize, hopSize: defaultHopSize)
        let peaks = pickOnsetPeaks(envelope)
        let hopDuration = Double(defaultHopSize) / sampleRate
        let tempo = estimateTempoBPM(envelope: envelope, hopDuration: hopDuration)
        let durationSeconds = Double(samples.count) / sampleRate
        let beatTimes = beatGrid(peakIndices: peaks,
                                 tempoBPM: tempo,
                                 hopDuration: hopDuration,
                                 durationSeconds: durationSeconds)
        let confidence = confidenceScore(peaks: peaks.count, beats: beatTimes.count, tempoBPM: tempo)
        return BeatAnalysis(tempoBPM: tempo, beatTimes: beatTimes, confidence: confidence)
    }

    /// Builds a half-wave-rectified energy-flux envelope. It is intentionally
    /// deterministic and cheap; the analyzer's AVAssetReader output already
    /// performs the mono 22.05 kHz decimation.
    static func onsetEnvelope(samples: [Float], frameSize: Int, hopSize: Int) -> [Float] {
        guard samples.count >= frameSize, frameSize > 0, hopSize > 0 else { return [] }
        let window = hannWindow(count: frameSize)
        var envelope: [Float] = []
        envelope.reserveCapacity((samples.count - frameSize) / hopSize + 1)

        var previousEnergy: Float = 0
        var frameStart = 0
        while frameStart + frameSize <= samples.count {
            var sum: Float = 0
            for i in 0..<frameSize {
                let sample = samples[frameStart + i] * window[i]
                sum += sample * sample
            }
            let energy = sqrt(sum / Float(frameSize))
            envelope.append(max(0, energy - previousEnergy))
            previousEnergy = energy
            frameStart += hopSize
        }
        return normalized(envelope)
    }

    static func pickOnsetPeaks(_ envelope: [Float],
                               medianRadius: Int = 6,
                               delta: Float = 0.08,
                               minDistance: Int = 4) -> [Int] {
        guard envelope.count >= 3 else { return [] }
        var peaks: [Int] = []
        for index in 1..<(envelope.count - 1) {
            let value = envelope[index]
            guard value >= envelope[index - 1], value > envelope[index + 1] else { continue }
            let start = max(0, index - medianRadius)
            let end = min(envelope.count - 1, index + medianRadius)
            let threshold = runningMedian(envelope[start...end]) + delta
            guard value >= threshold else { continue }
            if let last = peaks.last, index - last < minDistance {
                if value > envelope[last] {
                    peaks[peaks.count - 1] = index
                }
            } else {
                peaks.append(index)
            }
        }
        return peaks
    }

    static func estimateTempoBPM(envelope: [Float],
                                 hopDuration: Double,
                                 minBPM: Double = 60,
                                 maxBPM: Double = 200) -> Double {
        guard !envelope.isEmpty, hopDuration > 0 else { return 0 }
        let minLag = max(1, Int((60 / maxBPM / hopDuration).rounded()))
        let maxLag = max(minLag, Int((60 / minBPM / hopDuration).rounded()))
        guard envelope.count > maxLag else { return 0 }

        var bestLag = minLag
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var score: Float = 0
            for index in lag..<envelope.count {
                score += envelope[index] * envelope[index - lag]
            }
            let normalizedScore = score / Float(envelope.count - lag)
            if normalizedScore > bestScore {
                bestScore = normalizedScore
                bestLag = lag
            }
        }
        guard bestScore > 0 else { return 0 }
        return 60 / (Double(bestLag) * hopDuration)
    }

    static func beatGrid(peakIndices: [Int],
                         tempoBPM: Double,
                         hopDuration: Double,
                         durationSeconds: Double) -> [CMTime] {
        guard durationSeconds > 0 else { return [] }
        guard tempoBPM > 0, let firstPeak = peakIndices.first else {
            return peakIndices.map { quantizedTime(seconds: Double($0) * hopDuration) }
        }
        let interval = 60 / tempoBPM
        guard interval > 0 else { return [] }
        let firstBeat = (Double(firstPeak) * hopDuration).truncatingRemainder(dividingBy: interval)

        var beats: [CMTime] = []
        var seconds = firstBeat
        while seconds <= durationSeconds {
            beats.append(quantizedTime(seconds: seconds))
            seconds += interval
        }
        return beats
    }

    static func quantizedTime(seconds: Double) -> CMTime {
        let value = Int64((max(0, seconds) * Double(emittedTimescale)).rounded())
        return CMTime(value: value, timescale: emittedTimescale)
    }

    private static func hannWindow(count: Int) -> [Float] {
        guard count > 1 else { return [1] }
        return (0..<count).map { index in
            0.5 - 0.5 * cos(Float(2 * Double.pi) * Float(index) / Float(count - 1))
        }
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        guard let maxValue = values.max(), maxValue > 0 else { return values }
        return values.map { $0 / maxValue }
    }

    private static func runningMedian<C: Collection>(_ values: C) -> Float where C.Element == Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func confidenceScore(peaks: Int, beats: Int, tempoBPM: Double) -> Float {
        guard beats > 0, tempoBPM > 0 else { return 0 }
        let coverage = min(1, Float(peaks) / Float(max(1, beats)))
        return max(0.1, min(1, coverage))
    }
}
