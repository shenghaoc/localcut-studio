import Foundation
import CoreMedia

// MARK: - Silence Detection Parameters

/// Tuning parameters for the offline RMS-with-hysteresis silence detector.
public struct SilenceDetectionParameters: Hashable, Codable, Sendable {
    /// RMS level (dBFS) below which silence is considered to have opened.
    /// Default –40 dBFS is tuned for clean voice recordings.
    public var openThresholdDB: Float
    /// RMS level (dBFS) above which silence is considered to have closed.
    /// Must be ≥ `openThresholdDB` to form a valid hysteresis pair.
    public var closeThresholdDB: Float
    /// Minimum duration a quiet region must sustain to be classified as silence.
    public var minimumSilenceDuration: CMTime
    /// Padding added to each end of a detected silence range so the cut
    /// doesn't land exactly on a breath or trailing consonant.
    public var padding: CMTime

    public init(openThresholdDB: Float = -40,
                closeThresholdDB: Float = -35,
                minimumSilenceDuration: CMTime = CMTime(seconds: 0.6, preferredTimescale: 600),
                padding: CMTime = CMTime(seconds: 0.15, preferredTimescale: 600)) {
        self.openThresholdDB = min(openThresholdDB, closeThresholdDB)
        self.closeThresholdDB = max(openThresholdDB, closeThresholdDB)
        self.minimumSilenceDuration = minimumSilenceDuration.sanitized
        self.padding = padding.sanitized
    }

    private enum CodingKeys: String, CodingKey {
        case openThresholdDB, closeThresholdDB, minimumSilenceDuration, padding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawOpen = try c.decodeIfPresent(Float.self, forKey: .openThresholdDB) ?? -40
        let rawClose = try c.decodeIfPresent(Float.self, forKey: .closeThresholdDB) ?? -35
        // Enforce hysteresis invariant: open <= close.
        openThresholdDB = min(rawOpen, rawClose)
        closeThresholdDB = max(rawOpen, rawClose)
        let minDurCode = try c.decodeIfPresent(CMTimeCode.self, forKey: .minimumSilenceDuration)
        minimumSilenceDuration = minDurCode?.cmTime ?? CMTime(seconds: 0.6, preferredTimescale: 600)
        let paddingCode = try c.decodeIfPresent(CMTimeCode.self, forKey: .padding)
        padding = paddingCode?.cmTime ?? CMTime(seconds: 0.15, preferredTimescale: 600)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(openThresholdDB, forKey: .openThresholdDB)
        try c.encode(closeThresholdDB, forKey: .closeThresholdDB)
        try c.encode(CMTimeCode(minimumSilenceDuration), forKey: .minimumSilenceDuration)
        try c.encode(CMTimeCode(padding), forKey: .padding)
    }

    /// Open threshold as a linear amplitude (0…1).
    public var openThresholdLinear: Float {
        pow(10, openThresholdDB / 20)
    }

    /// Close threshold as a linear amplitude (0…1).
    public var closeThresholdLinear: Float {
        pow(10, closeThresholdDB / 20)
    }
}

// MARK: - Detected Silence

/// A time range identified as silence by the detector.
public struct DetectedSilence: Hashable, Sendable {
    /// The time range of the silence (including padding).
    public var range: CMTimeRange
    /// The original unpadded silence range.
    public var unpaddedRange: CMTimeRange

    public init(range: CMTimeRange, unpaddedRange: CMTimeRange) {
        self.range = range
        self.unpaddedRange = unpaddedRange
    }
}

extension DetectedSilence: Codable {
    private enum CodingKeys: String, CodingKey {
        case rangeStart, rangeDuration, unpaddedRangeStart, unpaddedRangeDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rangeStart = try c.decode(CMTimeCode.self, forKey: .rangeStart)
        let rangeDuration = try c.decode(CMTimeCode.self, forKey: .rangeDuration)
        range = CMTimeRange(start: rangeStart.cmTime, duration: rangeDuration.cmTime)
        let unpaddedStart = try c.decode(CMTimeCode.self, forKey: .unpaddedRangeStart)
        let unpaddedDuration = try c.decode(CMTimeCode.self, forKey: .unpaddedRangeDuration)
        unpaddedRange = CMTimeRange(start: unpaddedStart.cmTime, duration: unpaddedDuration.cmTime)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CMTimeCode(range.start), forKey: .rangeStart)
        try c.encode(CMTimeCode(range.duration), forKey: .rangeDuration)
        try c.encode(CMTimeCode(unpaddedRange.start), forKey: .unpaddedRangeStart)
        try c.encode(CMTimeCode(unpaddedRange.duration), forKey: .unpaddedRangeDuration)
    }
}

// MARK: - Proposed Cut Action

/// The suggested action for a proposed cut.
public enum ProposedCutAction: String, Hashable, Codable, Sendable {
    /// Remove the silence range from the clip (ripple-delete).
    case trim
    /// Split the clip at the silence boundaries.
    case split
}

// MARK: - Proposed Cut

/// A proposed edit derived from silence detection. Each proposal covers one
/// detected silence range and suggests an action.
public struct ProposedCut: Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The detected silence range (with padding applied).
    public var silenceRange: CMTimeRange
    /// The original unpadded silence range.
    public var unpaddedSilenceRange: CMTimeRange
    /// The suggested action for this silence.
    public var suggestedAction: ProposedCutAction
    /// Whether the user has opted to apply this cut in the review modal.
    public var isSelected: Bool

    public init(id: UUID = UUID(),
                silenceRange: CMTimeRange,
                unpaddedSilenceRange: CMTimeRange,
                suggestedAction: ProposedCutAction = .trim,
                isSelected: Bool = true) {
        self.id = id
        self.silenceRange = silenceRange
        self.unpaddedSilenceRange = unpaddedSilenceRange
        self.suggestedAction = suggestedAction
        self.isSelected = isSelected
    }
}

extension ProposedCut: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, silenceRangeStart, silenceRangeDuration
        case unpaddedSilenceRangeStart, unpaddedSilenceRangeDuration
        case suggestedAction, isSelected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let srStart = try c.decode(CMTimeCode.self, forKey: .silenceRangeStart)
        let srDuration = try c.decode(CMTimeCode.self, forKey: .silenceRangeDuration)
        silenceRange = CMTimeRange(start: srStart.cmTime, duration: srDuration.cmTime)
        let urStart = try c.decode(CMTimeCode.self, forKey: .unpaddedSilenceRangeStart)
        let urDuration = try c.decode(CMTimeCode.self, forKey: .unpaddedSilenceRangeDuration)
        unpaddedSilenceRange = CMTimeRange(start: urStart.cmTime, duration: urDuration.cmTime)
        suggestedAction = try c.decodeIfPresent(ProposedCutAction.self, forKey: .suggestedAction) ?? .trim
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(silenceRange.start), forKey: .silenceRangeStart)
        try c.encode(CMTimeCode(silenceRange.duration), forKey: .silenceRangeDuration)
        try c.encode(CMTimeCode(unpaddedSilenceRange.start), forKey: .unpaddedSilenceRangeStart)
        try c.encode(CMTimeCode(unpaddedSilenceRange.duration), forKey: .unpaddedSilenceRangeDuration)
        try c.encode(suggestedAction, forKey: .suggestedAction)
        try c.encode(isSelected, forKey: .isSelected)
    }
}

// MARK: - Silence Detection Error

/// Errors surfaced from the silence detection pass.
public enum SilenceDetectionError: Error, LocalizedError, Sendable {
    case noAudioTrack
    case emptyAudio
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "No audio track selected for silence detection."
        case .emptyAudio:
            "The selected audio track contains no audio data."
        case .unsupportedFormat(let detail):
            "Unsupported audio format: \(detail)"
        }
    }
}
