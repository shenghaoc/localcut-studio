import Foundation
import CoreMedia

// MARK: - Beat analysis model

/// Source-relative beat analysis for one audio asset.
///
/// `beatTimes` are relative to the audio file's start (not the timeline); the
/// editor projects them per clip through each clip's source-to-timeline mapping.
public struct BeatAnalysis: Equatable, Codable, Sendable {
    public var tempoBPM: Double
    public var beatTimes: [CMTime]
    public var confidence: Float

    public init(tempoBPM: Double, beatTimes: [CMTime], confidence: Float) {
        self.tempoBPM = tempoBPM
        self.beatTimes = beatTimes
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey { case tempoBPM, beatTimes, confidence }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tempoBPM = try c.decode(Double.self, forKey: .tempoBPM)
        beatTimes = try c.decode([CMTimeCode].self, forKey: .beatTimes).map(\.cmTime)
        confidence = try c.decode(Float.self, forKey: .confidence)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tempoBPM, forKey: .tempoBPM)
        try c.encode(beatTimes.map(CMTimeCode.init), forKey: .beatTimes)
        try c.encode(confidence, forKey: .confidence)
    }
}

/// A projected, timeline-relative beat used for ruler drawing and snapping.
public struct ProjectedBeatMarker: Identifiable, Hashable, Sendable {
    public let id: String
    public var time: CMTime

    public init(id: String, time: CMTime) {
        self.id = id
        self.time = time
    }
}

// MARK: - Errors

/// Errors raised while decoding an asset or running beat detection. The decode
/// cases originate in the app's AVFoundation `BeatAnalyzer`; `.insufficientSamples`
/// is also raised by the pure `BeatDetectionCore`.
public enum BeatAnalysisError: LocalizedError, Sendable {
    case noAudioTrack
    case readerConfigurationFailed
    case readerFailed(String)
    case insufficientSamples

    public var errorDescription: String? {
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
