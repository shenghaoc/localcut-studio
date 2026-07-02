import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import LocalCutCore

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
    /// The original capture source UUID from Program Mode landing. Used by
    /// `CompositionBuilder` to match scene-layer source refs to MediaItems
    /// when replaying layout tracks. `nil` for non-Program-Mode media.
    var captureSourceID: UUID?
    var duration: CMTime = .zero
    var naturalSize: CGSize = .zero
    var preferredTransform: CGAffineTransform = .identity
    var hasVideo = false
    var hasAudio = false

    /// Security-scoped bookmark to `url`, created at import. Persisted in the
    /// project document so the file can be re-resolved across launches under the
    /// sandbox (R1.2). `nil` until a bookmark could be created, or for media that
    /// lives inside the project bundle (the bundle's outer URL is the grant).
    var bookmark: Data?

    /// Bundle-relative path (`assets/<id>.<ext>`) when this media has been
    /// copied into the current `.lcbundle` project. `nil` for media that has
    /// not been placed in a bundle yet (legacy `.lcstudio` documents) or that
    /// the user has explicitly opted out of bundling (see `wantsBundling`).
    var bundleRelativePath: String?

    /// Whether this media should be **copied into** the bundle on the next
    /// bundle save. Defaults to `true` — the standard "include media in the
    /// project" expectation. A future "Don't copy" import option flips this
    /// to `false`, which the bundle save path then honours by leaving the
    /// ref external (bookmark-resolved) instead of stamping a bundled path.
    var wantsBundling: Bool = true

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

// MARK: - Project

/// The editable document: imported media plus the multi-track arrangement and
/// the render settings used for preview and export.
@Observable
final class Project {
    var name = "Untitled"
    var mediaItems: [MediaItem] = []
    var videoTracks: [Track]
    var audioTracks: [Track]
    var captionTracks: [CaptionTrack] = []
    /// Animated overlay clips. Ordered bottom-to-top; later entries render above
    /// earlier ones, matching the video-track stacking convention.
    var overlays: [OverlayClip] = []
    /// Phase 43 callout clips (arrow, box, step number, spotlight, blur region).
    var callouts: [CalloutClip] = []
    /// Phase 43 padded background preset. When non-nil, renders a background
    /// behind the clip with rounded corners, drop shadow, and inset margin.
    var paddedBackground: PaddedBackgroundPreset?
    /// Phase 43 screencast event logs that generated auto-zoom proposals.
    var screencastEventLogs: [ScreencastEventLog] = []
    /// Phase 44 keystroke overlay clips derived from event logs.
    var keystrokeOverlayClips: [KeystrokeOverlayClip] = []
    /// Phase 45 scene definitions for Program Mode.
    var sceneDoc: SceneDoc = SceneDoc()
    /// Phase 45 layout tracks from Program Mode sessions.
    var layoutTracks: [LayoutTrack] = []
    /// Bookmark data for overlay source files, keyed by overlay ID.
    var overlayBookmarks: [UUID: Data] = [:]
    /// Bundle-relative paths for overlay source files, keyed by overlay ID.
    var overlayBundlePaths: [UUID: String] = [:]

    /// Creates `OverlayClipDoc` array for persistence from the runtime overlays
    /// and their bookmark data.
    var overlayDocs: [OverlayClipDoc] {
        overlays.map { overlay in
            OverlayClipDoc(
                overlay: overlay,
                bookmark: overlayBookmarks[overlay.id] ?? Data(),
                bundleRelativePath: overlayBundlePaths[overlay.id])
        }
    }
    /// Timeline markers sorted by `time`. Mutation paths on `EditorModel`
    /// preserve the invariant so draw / lookup code can treat the list as
    /// ordered without re-sorting per frame.
    var markers: [TimelineMarker] = []

    /// Output canvas size for preview and export.
    var renderSize = CGSize(width: 1920, height: 1080)
    /// User-facing aspect profile for the render canvas. `renderSize` remains
    /// the AVFoundation source of truth; this is the preset/inspector label.
    var aspect: ProjectAspect = .widescreen16x9
    /// Output frame rate (frames per second).
    var frameRate: Double = 30
    /// Working colour space used by the compositor's `CIContext` and stamped
    /// onto every output `CVPixelBuffer` attachment.
    var workingColourSpace: WorkingColourSpace = .sRGB

    // MARK: - Audio master bus (P16) parameters

    /// Master-bus output gain (linear, 0…2 ≈ −∞…+6 dB). Defaults to unity so
    /// a project with no audio-bus edits renders bit-identically to today's
    /// behaviour.
    var masterGain: Float = 1
    /// Per-audio-track inputs on the bus. Tracks are matched by `id` lazily;
    /// a missing entry implies defaults (pan 0, gain 1).
    var trackInputs: [TrackInput] = []

    /// Phase 36 voice-cleanup insert settings. Defaults are fully bypassed so
    /// legacy projects and exports remain bit-identical until a user enables an
    /// insert or applies loudness normalisation.
    var voiceCleanup = VoiceCleanupSettings()

    // MARK: - Phase 39 finishing

    var coverFrame: CoverFrameDoc?

    init() {
        videoTracks = [Track(name: "V1", kind: .video)]
        audioTracks = [Track(name: "A1", kind: .audio)]
    }

    /// Looks up the bus input for a track, returning defaults when not yet
    /// authored. Callers that mutate read-then-write via `setTrackInput`.
    func trackInput(for trackID: Track.ID) -> TrackInput {
        trackInputs.first(where: { $0.id == trackID }) ?? TrackInput(id: trackID)
    }

    func media(for id: MediaItem.ID) -> MediaItem? {
        mediaItems.first { $0.id == id }
    }

    /// Longest end time across every track — the project's total duration.
    /// Caption tracks count too, so a final caption past the last clip extends
    /// the timeline rather than being clipped off the end. Markers are
    /// annotations, not content, so they do not contribute here.
    var duration: CMTime {
        let av = (videoTracks + audioTracks).reduce(CMTime.zero) { CMTimeMaximum($0, $1.endTime) }
        let captions = captionTracks.reduce(CMTime.zero) { CMTimeMaximum($0, $1.endTime) }
        return CMTimeMaximum(av, captions)
    }
}
