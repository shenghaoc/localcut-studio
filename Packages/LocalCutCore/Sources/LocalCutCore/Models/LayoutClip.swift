import Foundation
import CoreMedia

// MARK: - Layout clip

/// A clip on a layout track that stores a `SceneDefinition` snapshot at a
/// segment boundary. Re-exporting the landed project drives the same
/// compositor with the same scene definitions — the live mix replays
/// identically.
///
/// Layout clips are created when a Program Mode session stops and its
/// scene-switch records are partitioned into segments.
public struct LayoutClip: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// The time on the timeline where this clip starts.
    public var timelineStart: CMTimeCode
    /// The duration of this segment.
    public var duration: CMTimeCode
    /// The scene definition snapshot for this segment. Contains the
    /// full layer list with transforms, visibility, z-index, and opacity.
    public var sceneSnapshot: SceneDefinition
    /// Optional: transform keyframes at the segment boundaries for
    /// smooth transitions between scenes.
    public var transformKeyframes: Keyframed<Transform2D>

    public init(id: UUID = UUID(),
                timelineStart: CMTimeCode,
                duration: CMTimeCode,
                sceneSnapshot: SceneDefinition,
                transformKeyframes: Keyframed<Transform2D> = Keyframed(defaultValue: .identity)) {
        self.id = id
        self.timelineStart = timelineStart
        self.duration = duration
        self.sceneSnapshot = sceneSnapshot
        self.transformKeyframes = transformKeyframes
    }

    /// The end time of this clip on the timeline.
    public var timelineEnd: CMTimeCode {
        CMTimeCode(timelineStart.cmTime + duration.cmTime)
    }
}

// MARK: - Layout track doc

/// Persistence snapshot for a layout track. Stored alongside video and
/// audio tracks in `ProjectDocument`.
public struct LayoutTrackDoc: Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var isMuted: Bool
    public var clips: [LayoutClip]

    public init(id: UUID = UUID(),
                name: String = "Layout",
                isMuted: Bool = false,
                clips: [LayoutClip] = []) {
        self.id = id
        self.name = name
        self.isMuted = isMuted
        self.clips = clips
    }
}

// MARK: - Runtime layout track

/// Runtime model for a layout track. Similar to `Track` but holds
/// `LayoutClip`s instead of `Clip`s.
@Observable
@MainActor
public final class LayoutTrack: Identifiable {
    public let id: UUID
    public var name: String
    public var isMuted = false
    public var clips: [LayoutClip] = []

    public init(id: UUID = UUID(), name: String = "Layout") {
        self.id = id
        self.name = name
    }

    /// The first free time at the tail of the track.
    public var endTime: CMTimeCode {
        clips.reduce(CMTimeCode(CMTime(value: 0, timescale: 600))) { acc, clip in
            CMTimeMaximum(clip.timelineEnd.cmTime, acc.cmTime) == clip.timelineEnd.cmTime
                ? clip.timelineEnd : acc
        }
    }
}
