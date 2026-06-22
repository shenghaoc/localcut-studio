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

    var cmTime: CMTime {
        CMTime(value: value, timescale: timescale > 0 ? timescale : 600)
    }
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
    /// - v2 added `captionTracks` (PR #10).
    /// - v3 adds `workingColourSpace`, `markers`, the audio master bus (`audioBus` +
    ///   per-clip `volumeEnvelope`), and optional `bundleFormat` +
    ///   `MediaRef.bundleRelativePath` for the `.lcbundle` package format.
    ///   `bundleFormat` and `bundleRelativePath` are optional so a v2 single-file
    ///   reader can still open a v3 bundle's `project.json` — only the bundle
    ///   layout itself is gated on v3.
    /// The single-file `.lcstudio` save path keeps writing v2 to stay readable
    /// by older builds; the bundle save path writes v3.
    static let currentSchemaVersion = 3
    /// Schema version used by the single-file (`.lcstudio`) writer. Held at v2
    /// so a build that predates bundles can still open a freshly-written file.
    static let singleFileSchemaVersion = 2
    /// `bundleFormat` value written on the bundle save path. Versioned separately
    /// from `schemaVersion` so the bundle layout can evolve without re-rev'ing
    /// the document JSON itself.
    static let currentBundleFormat = "1"
    /// File extension for single-file project documents.
    static let fileExtension = "lcstudio"

    var schemaVersion: Int
    /// `"1"` when written into a `.lcbundle`; `nil` for legacy single-file
    /// documents. Optional so a v2 reader opens a v3 bundle's `project.json`.
    var bundleFormat: String?
    var name: String
    var renderWidth: Double
    var renderHeight: Double
    var frameRate: Double
    var workingColourSpace: WorkingColourSpace
    var media: [MediaRef]
    var videoTracks: [TrackDoc]
    var audioTracks: [TrackDoc]
    var captionTracks: [CaptionTrackDoc]
    var markers: [TimelineMarker]
    /// Audio master bus parameters (P16, schema v3+).
    var audioBus: AudioBusDoc

    init(schemaVersion: Int = ProjectDocument.currentSchemaVersion,
         bundleFormat: String? = nil,
         name: String,
         renderWidth: Double,
         renderHeight: Double,
         frameRate: Double,
         workingColourSpace: WorkingColourSpace = .sRGB,
         media: [MediaRef],
         videoTracks: [TrackDoc],
         audioTracks: [TrackDoc],
         captionTracks: [CaptionTrackDoc] = [],
         markers: [TimelineMarker] = [],
         audioBus: AudioBusDoc = AudioBusDoc()) {
        self.schemaVersion = schemaVersion
        self.bundleFormat = bundleFormat
        self.name = name
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.frameRate = frameRate
        self.workingColourSpace = workingColourSpace
        self.media = media
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.captionTracks = captionTracks
        self.markers = markers
        self.audioBus = audioBus
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bundleFormat, name, renderWidth, renderHeight, frameRate,
             workingColourSpace, media, videoTracks, audioTracks, captionTracks,
             markers, audioBus
    }

    // Lenient decoding: missing fields fall back to defaults and unknown keys are
    // ignored, so documents written by other schema versions still open (R4.2).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ProjectDocument.currentSchemaVersion
        bundleFormat = try c.decodeIfPresent(String.self, forKey: .bundleFormat)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        renderWidth = try c.decodeIfPresent(Double.self, forKey: .renderWidth) ?? 1920
        renderHeight = try c.decodeIfPresent(Double.self, forKey: .renderHeight) ?? 1080
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate) ?? 30
        // Decode through the raw string so an unknown value (a future schema's
        // additional case) falls back to `.sRGB` instead of throwing — the
        // `schemaVersion > current` guard in `EditorModel.load(document:from:)`
        // then runs as intended and the open path doesn't fail outright.
        if let raw = try c.decodeIfPresent(String.self, forKey: .workingColourSpace) {
            workingColourSpace = WorkingColourSpace(rawValue: raw) ?? .sRGB
        } else {
            workingColourSpace = .sRGB
        }
        media = try c.decodeIfPresent([MediaRef].self, forKey: .media) ?? []
        videoTracks = try c.decodeIfPresent([TrackDoc].self, forKey: .videoTracks) ?? []
        audioTracks = try c.decodeIfPresent([TrackDoc].self, forKey: .audioTracks) ?? []
        captionTracks = try c.decodeIfPresent([CaptionTrackDoc].self, forKey: .captionTracks) ?? []
        markers = try c.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        audioBus = try c.decodeIfPresent(AudioBusDoc.self, forKey: .audioBus) ?? AudioBusDoc()
    }
}

// MARK: - Audio master bus persistence (P16, schema v3+)

/// Codable snapshot of the project's master-bus parameters. Forward-compat
/// is handled by the outer `ProjectDocument.schemaVersion` (matches the
/// `CaptionTrackDoc` pattern — no inner version needed).
struct AudioBusDoc: Codable, Equatable {
    var masterGain: Float
    var trackInputs: [TrackInputDoc]

    init(masterGain: Float = 1, trackInputs: [TrackInputDoc] = []) {
        self.masterGain = masterGain
        self.trackInputs = trackInputs
    }

    private enum CodingKeys: String, CodingKey { case masterGain, trackInputs }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterGain = try c.decodeIfPresent(Float.self, forKey: .masterGain) ?? 1
        trackInputs = try c.decodeIfPresent([TrackInputDoc].self, forKey: .trackInputs) ?? []
    }
}

struct TrackInputDoc: Codable, Equatable {
    var trackID: UUID
    var pan: Float
    var gain: Float

    init(trackID: UUID, pan: Float = 0, gain: Float = 1) {
        self.trackID = trackID
        self.pan = pan
        self.gain = gain
    }

    private enum CodingKeys: String, CodingKey { case trackID, pan, gain }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try c.decode(UUID.self, forKey: .trackID)
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
    }
}

extension AudioBusDoc {
    init(project: Project) {
        self.init(
            masterGain: project.masterGain,
            trackInputs: project.trackInputs.map { TrackInputDoc(trackID: $0.id, pan: $0.pan, gain: $0.gain) })
    }
}

extension TrackInputDoc {
    var trackInput: TrackInput {
        TrackInput(id: trackID, pan: pan, gain: gain)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(bundleFormat, forKey: .bundleFormat)
        try c.encode(name, forKey: .name)
        try c.encode(renderWidth, forKey: .renderWidth)
        try c.encode(renderHeight, forKey: .renderHeight)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(media, forKey: .media)
        try c.encode(videoTracks, forKey: .videoTracks)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encode(captionTracks, forKey: .captionTracks)
    }
}

// MARK: - Caption track persistence

/// Codable lane of caption lines, mirroring `CaptionTrack`. The `id` round-trips
/// across save/load so undo steps and external references survive a document
/// open. Legacy documents without an `id` get a fresh UUID on decode.
struct CaptionTrackDoc: Codable, Equatable {
    var id: UUID
    var name: String
    var isMuted: Bool
    var defaultStyle: CaptionStyle
    var lines: [CaptionLine]

    init(id: UUID = UUID(), name: String, isMuted: Bool,
         defaultStyle: CaptionStyle, lines: [CaptionLine]) {
        self.id = id
        self.name = name
        self.isMuted = isMuted
        self.defaultStyle = defaultStyle
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case id, name, isMuted, defaultStyle, lines }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        defaultStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .defaultStyle) ?? .identity
        lines = try c.decodeIfPresent([CaptionLine].self, forKey: .lines) ?? []
    }
}

/// A referenced source media file: a security-scoped bookmark plus the metadata
/// needed to reconstruct a `MediaItem` without re-decoding the asset.
///
/// In the `.lcbundle` format a `MediaRef` may additionally carry a
/// `bundleRelativePath` pointing at `assets/<id>.<ext>` inside the bundle. When
/// present, the loader resolves the asset off the bundle root directly — the
/// bundle's outer URL is the sandbox grant, so no per-file security-scoped
/// bookmark is needed for the copy. External-only refs (bundleRelativePath ==
/// nil) keep going through the bookmark path exactly as before.
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
    /// `assets/<id>.<ext>` for media copied into the bundle. `nil` for legacy
    /// single-file documents and for external-only refs ("Don't copy" at import).
    var bundleRelativePath: String?

    init(id: UUID,
         displayName: String,
         bookmark: Data,
         duration: CMTimeCode,
         naturalWidth: Double,
         naturalHeight: Double,
         preferredTransform: TransformCode,
         hasVideo: Bool,
         hasAudio: Bool,
         bundleRelativePath: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.duration = duration
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.preferredTransform = preferredTransform
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.bundleRelativePath = bundleRelativePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, bookmark, duration, naturalWidth, naturalHeight,
             preferredTransform, hasVideo, hasAudio, bundleRelativePath
    }

    // Custom decoder so the new optional `bundleRelativePath` decodes leniently
    // (a v2 single-file document simply omits it).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark) ?? Data()
        duration = try c.decode(CMTimeCode.self, forKey: .duration)
        naturalWidth = try c.decode(Double.self, forKey: .naturalWidth)
        naturalHeight = try c.decode(Double.self, forKey: .naturalHeight)
        preferredTransform = try c.decode(TransformCode.self, forKey: .preferredTransform)
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        bundleRelativePath = try c.decodeIfPresent(String.self, forKey: .bundleRelativePath)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(bookmark, forKey: .bookmark)
        try c.encode(duration, forKey: .duration)
        try c.encode(naturalWidth, forKey: .naturalWidth)
        try c.encode(naturalHeight, forKey: .naturalHeight)
        try c.encode(preferredTransform, forKey: .preferredTransform)
        try c.encode(hasVideo, forKey: .hasVideo)
        try c.encode(hasAudio, forKey: .hasAudio)
        try c.encodeIfPresent(bundleRelativePath, forKey: .bundleRelativePath)
    }
}

/// Codable lane of clips.
struct TrackDoc: Codable, Equatable {
    /// Stable identity (schema v3+). Persisted so the audio master bus's
    /// `TrackInput` entries — which key off `Track.id` — still match the
    /// runtime tracks after a save/load round trip. Legacy documents without
    /// an `id` decode to a fresh UUID; bus inputs from those older saves
    /// won't match by id and are silently ignored (the inspector can re-author).
    var id: UUID
    var name: String
    var kind: String          // TrackKind raw ("video" / "audio")
    var isMuted: Bool
    var clips: [ClipDoc]

    init(id: UUID = UUID(), name: String, kind: String, isMuted: Bool, clips: [ClipDoc]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isMuted = isMuted
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, isMuted, clips }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
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
    /// Per-clip volume envelope (P16, schema v3+). Empty envelope on legacy
    /// documents leaves audio mixing bit-identical to the pre-bus path.
    var volumeEnvelope: VolumeEnvelope

    init(mediaID: UUID,
         sourceStart: CMTimeCode,
         duration: CMTimeCode,
         timelineStart: CMTimeCode,
         opacity: Float,
         effects: [Effect],
         transition: TransitionDoc?,
         volumeEnvelope: VolumeEnvelope = VolumeEnvelope()) {
        self.mediaID = mediaID
        self.sourceStart = sourceStart
        self.duration = duration
        self.timelineStart = timelineStart
        self.opacity = opacity
        self.effects = effects
        self.transition = transition
        self.volumeEnvelope = volumeEnvelope
    }

    private enum CodingKeys: String, CodingKey {
        case mediaID, sourceStart, duration, timelineStart, opacity, effects, transition, volumeEnvelope
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
        volumeEnvelope = try c.decodeIfPresent(VolumeEnvelope.self, forKey: .volumeEnvelope) ?? VolumeEnvelope()
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
            workingColourSpace: project.workingColourSpace,
            media: project.mediaItems.map(MediaRef.init(item:)),
            videoTracks: project.videoTracks.map(TrackDoc.init(track:)),
            audioTracks: project.audioTracks.map(TrackDoc.init(track:)),
            captionTracks: project.captionTracks.map(CaptionTrackDoc.init(track:)),
            markers: project.markers,
            audioBus: AudioBusDoc(project: project))
    }
}

extension CaptionTrackDoc {
    init(track: CaptionTrack) {
        self.init(
            id: track.id,
            name: track.name,
            isMuted: track.isMuted,
            defaultStyle: track.defaultStyle,
            lines: track.lines)
    }

    /// Rebuilds a runtime `CaptionTrack` from the stored values, preserving
    /// the original UUID so undo steps and external references survive open.
    func makeTrack() -> CaptionTrack {
        let track = CaptionTrack(id: id, name: name, lines: lines)
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
            hasAudio: item.hasAudio,
            bundleRelativePath: item.bundleRelativePath)
    }
}

extension TrackDoc {
    init(track: Track) {
        self.init(
            id: track.id,
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
            transition: clip.transition.map(TransitionDoc.init(transition:)),
            volumeEnvelope: clip.volumeEnvelope)
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
             transition: transition?.makeTransition(),
             volumeEnvelope: volumeEnvelope)
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
