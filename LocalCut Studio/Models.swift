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
