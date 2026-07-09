import Foundation
import AVFoundation

// MARK: - Transcription Availability

/// Result of the three-step availability gate for on-device speech recognition.
public enum TranscriptionAvailability: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case unavailableLocale
    case onDeviceUnavailable
    case notDetermined

    public var isReady: Bool { self == .authorized }

    public var displayMessage: String {
        switch self {
        case .authorized: "Speech recognition is available."
        case .denied: "Speech recognition access was denied. Grant permission in System Settings > Privacy & Security > Speech Recognition."
        case .restricted: "Speech recognition is restricted on this device."
        case .unavailableLocale: "Speech recognition is not available for the selected language."
        case .onDeviceUnavailable: "On-device speech recognition is not supported for this language on this Mac."
        case .notDetermined: "Speech recognition permission has not been requested yet."
        }
    }
}

// MARK: - Transcription Locale Choice

/// How the transcription locale was selected.
public enum TranscriptionLocaleSource: String, Codable, Sendable {
    case userOverride
    case assetMetadata
    case systemFallback
}

/// A locale chosen for transcription with its provenance.
public struct TranscriptionLocaleChoice: Equatable, Sendable {
    public let locale: Locale
    public let source: TranscriptionLocaleSource

    public init(locale: Locale, source: TranscriptionLocaleSource) {
        self.locale = locale
        self.source = source
    }
}

// MARK: - Transcription Progress

/// Progress updates emitted during windowed transcription.
public struct TranscriptionProgress: Equatable, Sendable {
    public let currentWindow: Int
    public let totalWindows: Int

    public var fractionComplete: Double {
        guard totalWindows > 0 else { return 0 }
        return Double(currentWindow) / Double(totalWindows)
    }

    public var percentComplete: Int {
        Int(fractionComplete * 100)
    }

    public init(currentWindow: Int, totalWindows: Int) {
        self.currentWindow = currentWindow
        self.totalWindows = totalWindows
    }
}

// MARK: - Transcription Warning

/// Warnings surfaced during or after transcription.
public enum TranscriptionWarning: Equatable, Sendable {
    /// VAD found no speech in the audio.
    case noSpeechDetected
    /// Overlap region was ambiguous and could not be safely deduped.
    /// TODO: Not yet produced by the stitcher — reserved for future use.
    case ambiguousOverlap(windowIndex: Int)
    /// NLLanguageRecognizer disagrees with the chosen locale.
    case languageMismatch(detected: String, chosen: String)
    /// A caption line had zero duration and was dropped.
    case zeroDurationLineDropped
    /// A caption line was empty and was dropped.
    case emptyLineDropped
    /// DRM or format error during audio extraction.
    /// TODO: Audio extraction failures are thrown as errors, not surfaced as warnings.
    case audioExtractionFailed(String)

    public var displayMessage: String {
        switch self {
        case .noSpeechDetected:
            "No speech was detected in the audio."
        case .ambiguousOverlap(let index):
            "Ambiguous overlap at window \(index); some words may be duplicated."
        case .languageMismatch(let detected, let chosen):
            "Detected language (\(detected)) does not match the selected language (\(chosen)). Results may be incorrect — re-run as \(detected)?"
        case .zeroDurationLineDropped:
            "A caption line with zero duration was dropped."
        case .emptyLineDropped:
            "An empty caption line was dropped."
        case .audioExtractionFailed(let reason):
            "Audio extraction failed: \(reason)"
        }
    }
}

// MARK: - Caption Transcription Proposal

/// A single proposed caption line before the user accepts or skips it.
public struct CaptionProposalLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The proposed caption line, ready to be added to a CaptionTrack if accepted.
    public var proposedLine: CaptionLine
    /// Whether the user has accepted this line.
    public var isAccepted: Bool
    /// Whether the user has skipped this line.
    public var isSkipped: Bool

    public init(id: UUID = UUID(),
                proposedLine: CaptionLine,
                isAccepted: Bool = false,
                isSkipped: Bool = false) {
        self.id = id
        self.proposedLine = proposedLine
        self.isAccepted = isAccepted
        self.isSkipped = isSkipped
    }

    /// Converts to a CaptionLine suitable for insertion into a CaptionTrack.
    /// Returns nil if the line was skipped.
    public func toCaptionLine() -> CaptionLine? {
        guard isAccepted, !isSkipped else { return nil }
        return proposedLine
    }
}

/// The full proposal surfaced by the review modal.
public struct CaptionTranscriptionProposal: Equatable, Sendable {
    public var lines: [CaptionProposalLine]
    public var warnings: [TranscriptionWarning]
    public var locale: Locale
    public var sourceClipID: UUID?

    public init(lines: [CaptionProposalLine] = [],
                warnings: [TranscriptionWarning] = [],
                locale: Locale,
                sourceClipID: UUID? = nil) {
        self.lines = lines
        self.warnings = warnings
        self.locale = locale
        self.sourceClipID = sourceClipID
    }

    /// Lines the user has accepted.
    public var acceptedLines: [CaptionLine] {
        lines.compactMap { $0.toCaptionLine() }
    }

    /// Lines the user has skipped.
    public var skippedCount: Int {
        lines.filter { $0.isSkipped }.count
    }

    /// Whether any line has a language mismatch warning.
    public var hasLanguageMismatch: Bool {
        warnings.contains { if case .languageMismatch = $0 { return true }; return false }
    }

    /// The detected language from a mismatch warning, if any.
    public var detectedLanguage: String? {
        for warning in warnings {
            if case .languageMismatch(let detected, _) = warning { return detected }
        }
        return nil
    }
}

// MARK: - Transcription Request

/// Configuration for a transcription run.
public struct CaptionTranscriptionRequest: Equatable, Sendable {
    public let clipID: UUID
    public let sourceStart: CMTime
    public let duration: CMTime
    public let timelineStart: CMTime
    public let locale: Locale
    /// Speed curve for timeline mapping. Nil means identity (1.0x).
    public let speedCurve: Keyframed<Float>?

    public init(clipID: UUID,
                sourceStart: CMTime,
                duration: CMTime,
                timelineStart: CMTime,
                locale: Locale,
                speedCurve: Keyframed<Float>? = nil) {
        self.clipID = clipID
        self.sourceStart = sourceStart
        self.duration = duration
        self.timelineStart = timelineStart
        self.locale = locale
        self.speedCurve = speedCurve
    }
}
