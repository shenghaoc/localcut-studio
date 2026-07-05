import Foundation
import LocalCutCore

// MARK: - Interchange Warning

/// A typed warning emitted during interchange serialization.
/// Warnings are user-displayable and carry enough context to identify the
/// source timeline element.
struct InterchangeWarning: Equatable, Sendable, CustomStringConvertible {
    enum Kind: String, Equatable, Sendable {
        case zeroFrameClip
        case orphanTransition
        case missingSource
        case nonUniformSpeedCurve
        case transitionDegraded
        case unsupportedFeature
        case serializationFailure
    }

    let kind: Kind
    let message: String
    /// Optional context: track name or ID.
    let trackName: String?
    /// Optional context: clip name or ID.
    let clipName: String?

    init(_ kind: Kind, _ message: String,
         trackName: String? = nil, clipName: String? = nil) {
        self.kind = kind
        self.message = message
        self.trackName = trackName
        self.clipName = clipName
    }

    var description: String {
        var parts: [String] = []
        if let track = trackName { parts.append("[\(track)]") }
        if let clip = clipName { parts.append("[\(clip)]") }
        parts.append(message)
        return parts.joined(separator: " ")
    }
}

// MARK: - Warning Builders

/// Builds warnings for dropped zero-frame clips.
func zeroFrameClipWarning(mediaID: UUID, trackName: String) -> InterchangeWarning {
    InterchangeWarning(
        .zeroFrameClip,
        "Clip \(mediaID.uuidString.prefix(8)) collapsed to zero frames after snapping and was dropped.",
        trackName: trackName)
}

/// Builds warnings for orphan transitions (no adjacent clip pair).
func orphanTransitionWarning(clipID: UUID, trackName: String) -> InterchangeWarning {
    InterchangeWarning(
        .orphanTransition,
        "Transition on clip \(clipID.uuidString.prefix(8)) has no adjacent clip pair and was dropped.",
        trackName: trackName)
}

/// Builds warnings for missing source references.
func missingSourceWarning(mediaID: UUID, trackName: String, clipName: String?) -> InterchangeWarning {
    InterchangeWarning(
        .missingSource,
        "Source media \(mediaID.uuidString.prefix(8)) not found; emitted as MissingReference.",
        trackName: trackName,
        clipName: clipName)
}

/// Builds warnings for non-uniform speed curves.
func nonUniformSpeedWarning(clipID: UUID, trackName: String) -> InterchangeWarning {
    InterchangeWarning(
        .nonUniformSpeedCurve,
        "Clip \(clipID.uuidString.prefix(8)) has a non-uniform speed curve; source_range adjusted to average ratio. Variation won't round-trip into tools that don't read metadata.localcut.",
        trackName: trackName)
}

/// Builds warnings for transitions degraded to straight cuts.
func transitionDegradedWarning(clipID: UUID, trackName: String,
                                originalType: String) -> InterchangeWarning {
    InterchangeWarning(
        .transitionDegraded,
        "Transition '\(originalType)' on clip \(clipID.uuidString.prefix(8)) degraded to straight cut in EDL.",
        trackName: trackName)
}

/// Builds a warning for unsupported features preserved only as opaque metadata.
func unsupportedFeatureWarning(feature: String, trackName: String?) -> InterchangeWarning {
    InterchangeWarning(
        .unsupportedFeature,
        "Feature '\(feature)' preserved as opaque metadata under metadata.localcut.",
        trackName: trackName)
}

/// Builds a warning for serialization failure during bundle export.
func serializationFailureWarning(detail: String) -> InterchangeWarning {
    InterchangeWarning(
        .serializationFailure,
        "Interchange serialization failed: \(detail)")
}
