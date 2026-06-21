import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Helpers

extension CMTimeRange {
    /// Whether this range overlaps another range (positive-duration intersection).
    func intersects(_ other: CMTimeRange) -> Bool {
        intersection(other).duration > .zero
    }
}

// MARK: - Media

/// A source media file imported into the project's media bin.
///
/// Backed by an `AVURLAsset`. Metadata (duration, natural size, orientation) is
/// loaded asynchronously at import time so the rest of the app can treat it as
/// readily available, mirroring the role of a decoded media handle in the
/// browser original.
@Observable
final class MediaItem: Identifiable {
    let id = UUID()
    let url: URL
    let asset: AVURLAsset

    var name: String
    var duration: CMTime = .zero
    var naturalSize: CGSize = .zero
    var preferredTransform: CGAffineTransform = .identity
    var hasVideo = false
    var hasAudio = false

    /// Poster frame shown in the media bin. Generated lazily after import.
    var thumbnail: CGImage?

    init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.name = url.deletingPathExtension().lastPathComponent
    }

    var durationSeconds: Double { duration.seconds.isFinite ? duration.seconds : 0 }
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

    /// Returns the nearest `timelineStart` for a clip of the given duration such
    /// that it does not overlap any existing clip. If the desired position already
    /// fits, returns it unchanged; otherwise snaps to just after the overlapping
    /// clip's end.
    func nearestNonOverlappingStart(for duration: CMTime, desired start: CMTime) -> CMTime {
        let sorted = clips.sorted { $0.timelineStart < $1.timelineStart }
        var candidate = start
        var didMove = true

        while didMove {
            didMove = false
            let candidateRange = CMTimeRange(start: candidate, duration: duration)
            for clip in sorted {
                let clipRange = CMTimeRange(start: clip.timelineStart, duration: clip.duration)
                guard candidateRange.intersects(clipRange) else { continue }
                candidate = clip.timelineEnd
                didMove = true
                break
            }
        }

        return candidate
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
