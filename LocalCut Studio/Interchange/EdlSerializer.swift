import Foundation
import CoreMedia
import LocalCutCore

// MARK: - EDL Serialization Options

struct EdlSerializationOptions: Sendable {
    /// The title for the EDL header.
    var title: String
    /// Which video track index to export (0-based). CMX3600 is single-track.
    var videoTrackIndex: Int

    init(title: String = "LocalCut Export", videoTrackIndex: Int = 0) {
        self.title = title
        self.videoTrackIndex = videoTrackIndex
    }
}

// MARK: - EDL Serializer

/// Serializes a `ProjectDocument` to CMX3600 EDL format.
/// Returns the EDL text and any warnings.
func serializeTimelineToEdl(_ doc: ProjectDocument,
                            options: EdlSerializationOptions = EdlSerializationOptions())
    -> (edl: String, warnings: [InterchangeWarning]) {
    var warnings: [InterchangeWarning] = []
    let timebase = interchangeTimebase(for: doc)

    // Select the video track.
    guard options.videoTrackIndex >= 0, options.videoTrackIndex < doc.videoTracks.count else {
        return ("", [serializationFailureWarning(detail: "No video track at index \(options.videoTrackIndex).")])
    }
    let track = doc.videoTracks[options.videoTrackIndex]

    // Build media lookup.
    let mediaLookup = Dictionary(doc.media.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })

    // Record timecode starts at 01:00:00:00.
    // Use nominalFPS (not rate) because formatTimecode divides by nominalFPS.
    let recordStartFrames = timebase.nominalFPS * 3600 // 1 hour in nominal frames.

    // Frame rate for EDL is rounded integer, non-drop-frame.
    let edlFPS = timebase.nominalFPS
    let isFractional = timebase.frameDurationTimescale > 1

    // Snap clips.
    let snappedClips = snapTrackClips(track.clips, timebase: timebase)
    let keptClipIndices = Set(snappedClips.map(\.sourceIndex))
    for index in track.clips.indices where !keptClipIndices.contains(index) {
        warnings.append(zeroFrameClipWarning(
            mediaID: track.clips[index].mediaID, trackName: track.name))
    }

    // Reel name dedup.
    var reelCounts: [String: Int] = [:]
    var allocatedReels = Set<String>()

    var lines: [String] = []

    // Header.
    lines.append("TITLE: \(options.title)")
    if isFractional {
        let fpsDouble = Double(timebase.rate) / Double(timebase.frameDurationTimescale)
        lines.append("* LOCALCUT: RATE \(String(format: "%.2f", fpsDouble)) ROUNDED TO \(edlFPS) NDF")
    }
    lines.append("")

    for (index, ic) in snappedClips.enumerated() {
        let eventNumber = String(format: "%03d", index + 1)

        // Reel name.
        let reelName: String
        let mediaRef = mediaLookup[ic.mediaID]
        if mediaRef == nil {
            reelName = "AX"
            warnings.append(missingSourceWarning(
                mediaID: ic.mediaID, trackName: track.name, clipName: nil))
        } else {
            reelName = makeReelName(
                displayName: mediaRef!.displayName,
                counts: &reelCounts,
                allocated: &allocatedReels)
        }

        // Track designator: always "V" for video.
        let trackDesignator = "V"

        // Transition: for EDL, all transitions become straight cuts.
        if ic.doc.transition != nil, index > 0 {
            let transitionType = ic.doc.transition!.type
            warnings.append(transitionDegradedWarning(
                clipID: ic.doc.mediaID,
                trackName: track.name,
                originalType: transitionType))
        }

        let transitionField = "C" // Cut.

        // Source in/out timecode — references actual source media range.
        // For speed-ramped clips, ic.doc.duration is the source media duration;
        // ic.sourceDuration is the snapped timeline duration.
        let sourceInFrames = timebase.frames(time: ic.sourceStart)
        let sourceOutFrames = sourceInFrames + timebase.frames(time: ic.doc.duration.cmTime)

        // Record in/out timecode.
        let recordInFrames = recordStartFrames + timebase.frames(time: ic.timelineStart)
        let recordOutFrames = recordInFrames + timebase.frames(time: ic.timelineDuration)

        let sourceInTC = formatTimecode(frames: sourceInFrames, timebase: timebase)
        let sourceOutTC = formatTimecode(frames: sourceOutFrames, timebase: timebase)
        let recordInTC = formatTimecode(frames: recordInFrames, timebase: timebase)
        let recordOutTC = formatTimecode(frames: recordOutFrames, timebase: timebase)

        // Event line.
        let eventLine = "\(eventNumber)  \(reelName.padding(toLength: 8, withPad: " ", startingAt: 0)) \(trackDesignator)     \(transitionField)     \(sourceInTC) \(sourceOutTC) \(recordInTC) \(recordOutTC)"
        lines.append(eventLine)

        // Comment with clip name.
        if let name = mediaRef?.displayName {
            lines.append("* FROM CLIP NAME: \(name)")
        }

        // Speed curve comment.
        if let speedCurve = ic.doc.speedCurve,
           TimeRemapping.hasNonIdentitySpeed(speedCurve) {
            if !isSpeedCurveUniform(speedCurve) {
                warnings.append(nonUniformSpeedWarning(
                    clipID: ic.doc.mediaID, trackName: track.name))
                lines.append("* LOCALCUT: SPEED RAMP (NON-UNIFORM) — METADATA LOST IN EDL")
            } else {
                let speed = TimeRemapping.clampedSpeed(speedCurve.defaultValue)
                lines.append("* LOCALCUT: SPEED \(String(format: "%.2f", speed))x — METADATA LOST IN EDL")
            }
        }

        lines.append("")

    }

    return (lines.joined(separator: "\n"), warnings)
}

// MARK: - Reel Name Normalization

/// Creates a deterministic, unique reel name from a display name.
/// Rules:
/// - Uppercase alphanumeric only.
/// - Max 8 characters.
/// - Deterministic dedup suffix if collision.
private func makeReelName(displayName: String,
                          counts: inout [String: Int],
                          allocated: inout Set<String>) -> String {
    // Strip to uppercase alphanumeric.
    let cleaned = displayName.uppercased()
        .filter { $0.isLetter || $0.isNumber }
        .prefix(8)
    let base = String(cleaned)

    guard !base.isEmpty else {
        return makeReelName(displayName: "CLIP", counts: &counts, allocated: &allocated)
    }

    if !allocated.contains(base) {
        allocated.insert(base)
        counts[base] = 1
        return base
    }

    var count = counts[base, default: 1]
    while true {
        let rawSuffix = String(count)
        let suffix = rawSuffix.count >= 8 ? String(rawSuffix.suffix(7)) : rawSuffix
        let maxBaseLen = max(1, 8 - suffix.count)
        let candidate = String(base.prefix(maxBaseLen)) + suffix
        count += 1
        counts[base] = count
        if !allocated.contains(candidate) {
            allocated.insert(candidate)
            return candidate
        }
    }
}

// MARK: - Helpers
