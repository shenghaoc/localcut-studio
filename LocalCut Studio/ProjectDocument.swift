import Foundation
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Document content type

extension UTType {
    /// The `.lcstudio` project document type. Declared dynamically from the file
    /// extension so no `Info.plist` type declaration is required for the in-app
    /// New/Open/Save lifecycle. (Full Finder/double-click integration would add
    /// an exported `UTExportedTypeDeclarations` entry; out of scope for v1.)
    static let lcStudioProject = UTType(filenameExtension: ProjectDocument.fileExtension,
                                        conformingTo: .data) ?? .data
}

// MARK: - CMTime coding

/// Lossless `CMTime` representation: a rational `value/timescale` pair so timeline
/// math round-trips exactly (a `Double` of seconds would not).
nonisolated struct CMTimeCode: Codable, Equatable, Sendable {
    var value: Int64
    var timescale: Int32

    init(_ time: CMTime) {
        // Persist only numeric times; non-numeric (indefinite/invalid) collapse to zero.
        if time.isNumeric {
            self.value = time.value
            self.timescale = time.timescale
        } else {
            self.value = 0
            self.timescale = 600
        }
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

/// Codable form of an affine transform (the media's preferred orientation).
struct TransformCode: Codable, Equatable {
    var a, b, c, d, tx, ty: Double

    init(_ t: CGAffineTransform) {
        a = t.a; b = t.b; c = t.c; d = t.d; tx = t.tx; ty = t.ty
    }

    var cgTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

// MARK: - Document model

/// Codable snapshot of a `Project`, split from the runtime model. Holds plain
/// values plus security-scoped bookmarks instead of live `AVURLAsset`s, and a
/// `schemaVersion` for forward-compatible decoding (R4.2).
struct ProjectDocument: Codable, Equatable {
    /// Bumped when the on-disk schema changes incompatibly.
    static let currentSchemaVersion = 1
    /// File extension for project documents.
    static let fileExtension = "lcstudio"

    var schemaVersion: Int
    var name: String
    var renderWidth: Double
    var renderHeight: Double
    var frameRate: Double
    var media: [MediaRef]
    var videoTracks: [TrackDoc]
    var audioTracks: [TrackDoc]
    var captionTracks: [CaptionTrackDoc]

    init(schemaVersion: Int = ProjectDocument.currentSchemaVersion,
         name: String,
         renderWidth: Double,
         renderHeight: Double,
         frameRate: Double,
         media: [MediaRef],
         videoTracks: [TrackDoc],
         audioTracks: [TrackDoc],
         captionTracks: [CaptionTrackDoc] = []) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.frameRate = frameRate
        self.media = media
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.captionTracks = captionTracks
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, renderWidth, renderHeight, frameRate, media, videoTracks, audioTracks, captionTracks
    }

    // Lenient decoding: missing fields fall back to defaults and unknown keys are
    // ignored, so documents written by other schema versions still open (R4.2).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ProjectDocument.currentSchemaVersion
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        renderWidth = try c.decodeIfPresent(Double.self, forKey: .renderWidth) ?? 1920
        renderHeight = try c.decodeIfPresent(Double.self, forKey: .renderHeight) ?? 1080
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate) ?? 30
        media = try c.decodeIfPresent([MediaRef].self, forKey: .media) ?? []
        videoTracks = try c.decodeIfPresent([TrackDoc].self, forKey: .videoTracks) ?? []
        audioTracks = try c.decodeIfPresent([TrackDoc].self, forKey: .audioTracks) ?? []
        captionTracks = try c.decodeIfPresent([CaptionTrackDoc].self, forKey: .captionTracks) ?? []
    }
}

// MARK: - Caption track persistence

/// Codable lane of caption lines, mirroring `CaptionTrack`.
struct CaptionTrackDoc: Codable, Equatable {
    var name: String
    var isMuted: Bool
    var defaultStyle: CaptionStyle
    var lines: [CaptionLine]

    init(name: String, isMuted: Bool, defaultStyle: CaptionStyle, lines: [CaptionLine]) {
        self.name = name
        self.isMuted = isMuted
        self.defaultStyle = defaultStyle
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case name, isMuted, defaultStyle, lines }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        defaultStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .defaultStyle) ?? .identity
        lines = try c.decodeIfPresent([CaptionLine].self, forKey: .lines) ?? []
    }
}

/// A referenced source media file: a security-scoped bookmark plus the metadata
/// needed to reconstruct a `MediaItem` without re-decoding the asset.
struct MediaRef: Codable, Equatable {
    var id: UUID
    var displayName: String
    var bookmark: Data
    var duration: CMTimeCode
    var naturalWidth: Double
    var naturalHeight: Double
    var preferredTransform: TransformCode
    var hasVideo: Bool
    var hasAudio: Bool
}

/// Codable lane of clips.
struct TrackDoc: Codable, Equatable {
    var name: String
    var kind: String          // TrackKind raw ("video" / "audio")
    var isMuted: Bool
    var clips: [ClipDoc]

    init(name: String, kind: String, isMuted: Bool, clips: [ClipDoc]) {
        self.name = name
        self.kind = kind
        self.isMuted = isMuted
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey { case name, kind, isMuted, clips }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "video"
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        clips = try c.decodeIfPresent([ClipDoc].self, forKey: .clips) ?? []
    }
}

/// Codable placement of a clip, including its effect chain and incoming transition.
struct ClipDoc: Codable, Equatable {
    var mediaID: UUID
    var sourceStart: CMTimeCode
    var duration: CMTimeCode
    var timelineStart: CMTimeCode
    var opacity: Float
    var effects: [Effect]
    var transition: TransitionDoc?

    init(mediaID: UUID,
         sourceStart: CMTimeCode,
         duration: CMTimeCode,
         timelineStart: CMTimeCode,
         opacity: Float,
         effects: [Effect],
         transition: TransitionDoc?) {
        self.mediaID = mediaID
        self.sourceStart = sourceStart
        self.duration = duration
        self.timelineStart = timelineStart
        self.opacity = opacity
        self.effects = effects
        self.transition = transition
    }

    private enum CodingKeys: String, CodingKey {
        case mediaID, sourceStart, duration, timelineStart, opacity, effects, transition
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try c.decode(UUID.self, forKey: .mediaID)
        sourceStart = try c.decode(CMTimeCode.self, forKey: .sourceStart)
        duration = try c.decode(CMTimeCode.self, forKey: .duration)
        timelineStart = try c.decode(CMTimeCode.self, forKey: .timelineStart)
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        transition = try c.decodeIfPresent(TransitionDoc.self, forKey: .transition)
    }
}

/// Codable form of a clip-owned transition (the overlap is always re-derived).
struct TransitionDoc: Codable, Equatable {
    var type: String          // TransitionType raw
    var duration: CMTimeCode
}

// MARK: - Snapshot (Project → Document)

extension ProjectDocument {
    /// Captures the current arrangement and settings into a document. Media
    /// bookmarks must already be present on each `MediaItem` (created at import);
    /// a media item without a bookmark is stored with empty data and will require
    /// relinking on open.
    init(project: Project) {
        self.init(
            name: project.name,
            renderWidth: Double(project.renderSize.width),
            renderHeight: Double(project.renderSize.height),
            frameRate: project.frameRate,
            media: project.mediaItems.map(MediaRef.init(item:)),
            videoTracks: project.videoTracks.map(TrackDoc.init(track:)),
            audioTracks: project.audioTracks.map(TrackDoc.init(track:)),
            captionTracks: project.captionTracks.map(CaptionTrackDoc.init(track:)))
    }
}

extension CaptionTrackDoc {
    init(track: CaptionTrack) {
        self.init(
            name: track.name,
            isMuted: track.isMuted,
            defaultStyle: track.defaultStyle,
            lines: track.lines)
    }

    /// Rebuilds a runtime `CaptionTrack` from the stored values.
    func makeTrack() -> CaptionTrack {
        let track = CaptionTrack(name: name, lines: lines)
        track.isMuted = isMuted
        track.defaultStyle = defaultStyle
        return track
    }
}

extension MediaRef {
    init(item: MediaItem) {
        self.init(
            id: item.id,
            displayName: item.name,
            bookmark: item.bookmark ?? Data(),
            duration: CMTimeCode(item.duration),
            naturalWidth: Double(item.naturalSize.width),
            naturalHeight: Double(item.naturalSize.height),
            preferredTransform: TransformCode(item.preferredTransform),
            hasVideo: item.hasVideo,
            hasAudio: item.hasAudio)
    }
}

extension TrackDoc {
    init(track: Track) {
        self.init(
            name: track.name,
            kind: track.kind == .video ? "video" : "audio",
            isMuted: track.isMuted,
            clips: track.clips.map(ClipDoc.init(clip:)))
    }
}

extension ClipDoc {
    init(clip: Clip) {
        self.init(
            mediaID: clip.mediaID,
            sourceStart: CMTimeCode(clip.sourceStart),
            duration: CMTimeCode(clip.duration),
            timelineStart: CMTimeCode(clip.timelineStart),
            opacity: clip.opacity,
            effects: clip.effects,
            transition: clip.transition.map(TransitionDoc.init(transition:)))
    }
}

extension TransitionDoc {
    init(transition: Transition) {
        self.init(type: transition.type.rawValue, duration: CMTimeCode(transition.duration))
    }
}

// MARK: - Reconstruction (Document → runtime values)

extension ClipDoc {
    /// Rebuilds a runtime `Clip` (with a fresh identity) from the stored values.
    func makeClip() -> Clip {
        Clip(mediaID: mediaID,
             sourceStart: sourceStart.cmTime,
             duration: duration.cmTime,
             timelineStart: timelineStart.cmTime,
             opacity: opacity,
             effects: effects,
             transition: transition?.makeTransition())
    }
}

extension TransitionDoc {
    func makeTransition() -> Transition {
        Transition(type: TransitionType(rawValue: type) ?? .crossDissolve, duration: duration.cmTime)
    }
}

extension TrackDoc {
    var trackKind: TrackKind { kind == "audio" ? .audio : .video }
}

// MARK: - Serialization

extension ProjectDocument {
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(ProjectDocument.self, from: data)
    }
}
