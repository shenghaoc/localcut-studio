import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Media

/// A source media file imported into the project's media bin.
///
/// Backed by an `AVURLAsset`. Metadata (duration, natural size, orientation) is
/// loaded asynchronously at import time so the rest of the app can treat it as
/// readily available, mirroring the role of a decoded media handle in the
/// browser original.
@Observable
final class MediaItem: Identifiable {
    let id: UUID
    let url: URL
    let asset: AVURLAsset

    var name: String
    var duration: CMTime = .zero
    var naturalSize: CGSize = .zero
    var preferredTransform: CGAffineTransform = .identity
    var hasVideo = false
    var hasAudio = false

    /// Security-scoped bookmark to `url`, created at import. Persisted in the
    /// project document so the file can be re-resolved across launches under the
    /// sandbox (R1.2). `nil` until a bookmark could be created.
    var bookmark: Data?

    /// Poster frame shown in the media bin. Generated lazily after import.
    var thumbnail: CGImage?

    init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.name = url.deletingPathExtension().lastPathComponent
    }

    var durationSeconds: Double { duration.seconds.isFinite ? duration.seconds : 0 }

    /// Generates the poster frame from near the asset's start. Lives on the media
    /// item (not the editor) so a background decode task retains only this object,
    /// never the whole `EditorModel`.
    func loadThumbnail() async {
        guard hasVideo else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let time = CMTime(seconds: min(0.1, durationSeconds / 2), preferredTimescale: 600)
        if let result = try? await generator.image(at: time) {
            thumbnail = result.image
        }
    }
}

// MARK: - Timeline

enum TrackKind: Hashable {
    case video
    case audio
}

// MARK: - Colour Grading

/// Perceptual colour-adjustment parameters with neutral defaults and clamping.
struct ColourGrade: Hashable, Codable {
    var exposure: Float = 0        // CIExposureAdjust.inputEV, range [-2, 2]
    var contrast: Float = 1        // CIColorControls.inputContrast, range [0.5, 1.5]
    var saturation: Float = 1      // CIColorControls.inputSaturation, range [0, 2]
    var temperatureOffset: Float = 0  // CITemperatureAndTint offset from 6500K, range [-4000, 4000]
    var tintOffset: Float = 0         // CITemperatureAndTint offset from 0, range [-150, 150]

    static let neutral = ColourGrade()

    mutating func clamp() {
        exposure = max(-2, min(2, exposure))
        contrast = max(0.5, min(1.5, contrast))
        saturation = max(0, min(2, saturation))
        temperatureOffset = max(-4000, min(4000, temperatureOffset))
        tintOffset = max(-150, min(150, tintOffset))
    }
}

/// An effect that can be applied to a video clip's source frames.
enum Effect: Hashable, Codable {
    case colourGrade(ColourGrade)
    case lut(bookmark: Data)

    static func == (lhs: Effect, rhs: Effect) -> Bool {
        switch (lhs, rhs) {
        case (.colourGrade(let a), .colourGrade(let b)): a == b
        case (.lut(bookmark: let a), .lut(bookmark: let b)): a == b
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .colourGrade(let g): hasher.combine(0); hasher.combine(g)
        case .lut(bookmark: let d): hasher.combine(1); hasher.combine(d)
        }
    }
}

// MARK: - Transitions

/// The kinds of transition supported in v1.
enum TransitionType: String, Hashable, Codable, CaseIterable, Identifiable {
    /// A linear opacity cross-fade between the outgoing and incoming clips.
    case crossDissolve
    /// A directional bars-swipe handled by the custom compositor.
    case wipe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .wipe: "Wipe"
        }
    }

    /// SF Symbol used for the timeline glyph and inspector.
    var symbolName: String {
        switch self {
        case .crossDissolve: "circle.lefthalf.filled"
        case .wipe: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        }
    }
}

/// A transition placed at the cut where its owning (trailing) clip meets the
/// immediately-preceding adjacent clip on the same video track.
///
/// `duration` is the *requested* length; the actually-rendered overlap is
/// derived at build time and clamped to the available length of the two
/// neighbouring clips (see `TransitionLayout`). The overlap is never stored on
/// the clips themselves — adjacent clips stay butt-joined in authored time.
struct Transition: Identifiable, Hashable {
    let id: UUID
    var type: TransitionType
    var duration: CMTime

    init(id: UUID = UUID(), type: TransitionType = .crossDissolve, duration: CMTime) {
        self.id = id
        self.type = type
        self.duration = duration
    }

    /// Sensible default transition length (0.5s, R4.2), clamped to overlap when applied.
    static let defaultDuration = CMTime(value: 1, timescale: 2)
}

/// A single placement of (part of) a media item on a track's timeline.
struct Clip: Identifiable, Hashable {
    let id = UUID()
    var mediaID: MediaItem.ID

    /// In-point within the source media.
    var sourceStart: CMTime
    /// How much of the source plays on the timeline.
    var duration: CMTime
    /// Where the clip begins on the track's timeline.
    var timelineStart: CMTime

    /// Per-clip opacity used when compositing video layers (0...1).
    var opacity: Float = 1

    /// Ordered effect chain applied to every source frame of this clip.
    var effects: [Effect] = []

    /// A transition into this clip from the preceding adjacent clip, if any.
    /// The trailing clip owns the transition; the overlap is derived, not stored.
    var transition: Transition?

    var timelineEnd: CMTime { timelineStart + duration }

    var timeRangeInSource: CMTimeRange { CMTimeRange(start: sourceStart, duration: duration) }
}

/// An ordered lane of clips of a single kind.
@Observable
final class Track: Identifiable {
    let id = UUID()
    var name: String
    let kind: TrackKind
    var clips: [Clip] = []
    var isMuted = false

    init(name: String, kind: TrackKind) {
        self.name = name
        self.kind = kind
    }

    /// The first free time at the tail of the track, used for ripple-append.
    var endTime: CMTime {
        clips.reduce(.zero) { CMTimeMaximum($0, $1.timelineEnd) }
    }
}

// MARK: - Project

/// The editable document: imported media plus the multi-track arrangement and
/// the render settings used for preview and export.
@Observable
final class Project {
    var name = "Untitled"
    var mediaItems: [MediaItem] = []
    var videoTracks: [Track]
    var audioTracks: [Track]

    /// Output canvas size for preview and export.
    var renderSize = CGSize(width: 1920, height: 1080)
    /// Output frame rate (frames per second).
    var frameRate: Double = 30

    init() {
        videoTracks = [Track(name: "V1", kind: .video)]
        audioTracks = [Track(name: "A1", kind: .audio)]
    }

    func media(for id: MediaItem.ID) -> MediaItem? {
        mediaItems.first { $0.id == id }
    }

    /// Longest end time across every track — the project's total duration.
    var duration: CMTime {
        (videoTracks + audioTracks).reduce(.zero) { CMTimeMaximum($0, $1.endTime) }
    }
}
