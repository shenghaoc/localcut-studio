import Foundation
import CoreGraphics

// MARK: - Document model

/// Codable snapshot of a `Project`, split from the runtime model. Holds plain
/// values plus security-scoped bookmarks instead of live `AVURLAsset`s.
public struct ProjectDocument: Codable, Equatable, Sendable {
    // Bumped to 7 (single-file 6) in Phase 38b: `OverlayClip` persistence
    // added to `ProjectDocument.overlays`. Prior bump (6/5) was for look
    // effects in Phase 38a.
    public static let currentSchemaVersion = 7
    public static let singleFileSchemaVersion = 6
    public static let currentBundleFormat = "1"
    public static let fileExtension = "lcstudio"

    public var schemaVersion: Int
    public var bundleFormat: String?
    public var name: String
    public var renderWidth: Double
    public var renderHeight: Double
    public var frameRate: Double
    public var workingColourSpace: WorkingColourSpace
    public var media: [MediaRef]
    public var videoTracks: [TrackDoc]
    public var audioTracks: [TrackDoc]
    public var captionTracks: [CaptionTrackDoc]
    public var markers: [TimelineMarker]
    public var audioBus: AudioBusDoc
    public var overlays: [OverlayClipDoc]

    public init(schemaVersion: Int = ProjectDocument.currentSchemaVersion,
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
                audioBus: AudioBusDoc = AudioBusDoc(),
                overlays: [OverlayClipDoc] = []) {
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
        self.overlays = overlays
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bundleFormat, name, renderWidth, renderHeight, frameRate,
             workingColourSpace, media, videoTracks, audioTracks, captionTracks,
             markers, audioBus, overlays
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ProjectDocument.currentSchemaVersion
        bundleFormat = try c.decodeIfPresent(String.self, forKey: .bundleFormat)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        renderWidth = try c.decodeIfPresent(Double.self, forKey: .renderWidth) ?? 1920
        renderHeight = try c.decodeIfPresent(Double.self, forKey: .renderHeight) ?? 1080
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate) ?? 30
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
        overlays = try c.decodeIfPresent([OverlayClipDoc].self, forKey: .overlays) ?? []
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ProjectDocument.self, from: data)
    }
}

// MARK: - Audio master bus persistence

public struct AudioBusDoc: Codable, Equatable, Sendable {
    public var masterGain: Float
    public var trackInputs: [TrackInputDoc]
    public var voiceCleanup: VoiceCleanupSettings

    public init(masterGain: Float = 1,
                trackInputs: [TrackInputDoc] = [],
                voiceCleanup: VoiceCleanupSettings = VoiceCleanupSettings()) {
        self.masterGain = masterGain
        self.trackInputs = trackInputs
        self.voiceCleanup = voiceCleanup
    }

    private enum CodingKeys: String, CodingKey { case masterGain, trackInputs, voiceCleanup }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterGain = try c.decodeIfPresent(Float.self, forKey: .masterGain) ?? 1
        trackInputs = try c.decodeIfPresent([TrackInputDoc].self, forKey: .trackInputs) ?? []
        voiceCleanup = try c.decodeIfPresent(VoiceCleanupSettings.self, forKey: .voiceCleanup) ?? VoiceCleanupSettings()
    }
}

public struct TrackInputDoc: Codable, Equatable, Sendable {
    public var trackID: UUID
    public var pan: Float
    public var gain: Float

    public init(trackID: UUID, pan: Float = 0, gain: Float = 1) {
        self.trackID = trackID
        self.pan = pan
        self.gain = gain
    }

    private enum CodingKeys: String, CodingKey { case trackID, pan, gain }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try c.decode(UUID.self, forKey: .trackID)
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
    }

    public var trackInput: TrackInput {
        TrackInput(id: trackID, pan: pan, gain: gain)
    }
}

// MARK: - Caption track persistence

public struct CaptionTrackDoc: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isMuted: Bool
    public var defaultStyle: CaptionStyle
    public var lines: [CaptionLine]

    public init(id: UUID = UUID(), name: String, isMuted: Bool,
                defaultStyle: CaptionStyle, lines: [CaptionLine]) {
        self.id = id
        self.name = name
        self.isMuted = isMuted
        self.defaultStyle = defaultStyle
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case id, name, isMuted, defaultStyle, lines }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        defaultStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .defaultStyle) ?? .identity
        lines = try c.decodeIfPresent([CaptionLine].self, forKey: .lines) ?? []
    }

    /// Rebuilds a runtime `CaptionTrack` from the stored values.
    @MainActor
    public func makeTrack() -> CaptionTrack {
        let track = CaptionTrack(id: id, name: name, lines: lines)
        track.isMuted = isMuted
        track.defaultStyle = defaultStyle
        return track
    }
}

// MARK: - Media reference

public struct MediaRef: Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var bookmark: Data
    public var duration: CMTimeCode
    public var naturalWidth: Double
    public var naturalHeight: Double
    public var preferredTransform: TransformCode
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var bundleRelativePath: String?

    public init(id: UUID,
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

    public init(from decoder: any Decoder) throws {
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

    public func encode(to encoder: any Encoder) throws {
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

// MARK: - Track / Clip persistence

public struct TrackDoc: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: String
    public var isMuted: Bool
    public var clips: [ClipDoc]

    public init(id: UUID = UUID(), name: String, kind: String, isMuted: Bool, clips: [ClipDoc]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isMuted = isMuted
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, isMuted, clips }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "video"
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        clips = try c.decodeIfPresent([ClipDoc].self, forKey: .clips) ?? []
    }

    public var trackKind: TrackKind { kind == "audio" ? .audio : .video }
}

public struct ClipDoc: Codable, Equatable, Sendable {
    public var mediaID: UUID
    public var sourceStart: CMTimeCode
    public var duration: CMTimeCode
    public var timelineStart: CMTimeCode
    public var opacity: Float
    public var effects: [Effect]
    public var transition: TransitionDoc?
    public var volumeEnvelope: VolumeEnvelope
    public var speedCurve: Keyframed<Float>?
    public var preservePitch: Bool?
    public var pitchAlgorithm: TimePitchAlgorithm?

    public init(mediaID: UUID,
                sourceStart: CMTimeCode,
                duration: CMTimeCode,
                timelineStart: CMTimeCode,
                opacity: Float,
                effects: [Effect],
                transition: TransitionDoc?,
                volumeEnvelope: VolumeEnvelope = VolumeEnvelope(),
                speedCurve: Keyframed<Float>? = nil,
                preservePitch: Bool? = nil,
                pitchAlgorithm: TimePitchAlgorithm? = nil) {
        self.mediaID = mediaID
        self.sourceStart = sourceStart
        self.duration = duration
        self.timelineStart = timelineStart
        self.opacity = opacity
        self.effects = effects
        self.transition = transition
        self.volumeEnvelope = volumeEnvelope
        self.speedCurve = speedCurve
        self.preservePitch = preservePitch
        self.pitchAlgorithm = pitchAlgorithm
    }

    private enum CodingKeys: String, CodingKey {
        case mediaID, sourceStart, duration, timelineStart, opacity, effects,
             transition, volumeEnvelope, speedCurve, preservePitch, pitchAlgorithm
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try c.decode(UUID.self, forKey: .mediaID)
        sourceStart = try c.decode(CMTimeCode.self, forKey: .sourceStart)
        duration = try c.decode(CMTimeCode.self, forKey: .duration)
        timelineStart = try c.decode(CMTimeCode.self, forKey: .timelineStart)
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        transition = try c.decodeIfPresent(TransitionDoc.self, forKey: .transition)
        volumeEnvelope = try c.decodeIfPresent(VolumeEnvelope.self, forKey: .volumeEnvelope) ?? VolumeEnvelope()
        speedCurve = try c.decodeIfPresent(Keyframed<Float>.self, forKey: .speedCurve)
        preservePitch = try c.decodeIfPresent(Bool.self, forKey: .preservePitch)
        pitchAlgorithm = try c.decodeIfPresent(TimePitchAlgorithm.self, forKey: .pitchAlgorithm)
    }

    public func makeClip() -> Clip {
        Clip(mediaID: mediaID,
             sourceStart: sourceStart.cmTime,
             duration: duration.cmTime,
             timelineStart: timelineStart.cmTime,
             opacity: opacity,
             effects: effects,
             transition: transition?.makeTransition(),
             volumeEnvelope: volumeEnvelope,
             speedCurve: speedCurve ?? TimeRemapping.identitySpeedCurve,
             preservePitch: preservePitch ?? true,
             pitchAlgorithm: pitchAlgorithm ?? .timeDomain)
    }
}

public struct TransitionDoc: Codable, Equatable, Sendable {
    public var type: String
    public var duration: CMTimeCode
    public var wipeAngle: Double

    public init(type: String, duration: CMTimeCode, wipeAngle: Double = Transition.defaultWipeAngle) {
        self.type = type
        self.duration = duration
        self.wipeAngle = wipeAngle
    }

    private enum CodingKeys: String, CodingKey { case type, duration, wipeAngle }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        duration = try c.decode(CMTimeCode.self, forKey: .duration)
        wipeAngle = try c.decodeIfPresent(Double.self, forKey: .wipeAngle) ?? Transition.defaultWipeAngle
    }

    public func makeTransition() -> Transition {
        Transition(type: TransitionType(rawValue: type) ?? .crossDissolve,
                   duration: duration.cmTime,
                   wipeAngle: wipeAngle)
    }
}

// MARK: - Snapshot helpers (Project → Document)

extension CaptionTrackDoc {
    @MainActor
    public init(track: CaptionTrack) {
        self.init(
            id: track.id,
            name: track.name,
            isMuted: track.isMuted,
            defaultStyle: track.defaultStyle,
            lines: track.lines)
    }
}

extension TrackDoc {
    @MainActor
    public init(track: Track) {
        self.init(
            id: track.id,
            name: track.name,
            kind: track.kind == .video ? "video" : "audio",
            isMuted: track.isMuted,
            clips: track.clips.map(ClipDoc.init(clip:)))
    }
}

extension ClipDoc {
    public init(clip: Clip) {
        self.init(
            mediaID: clip.mediaID,
            sourceStart: CMTimeCode(clip.sourceStart),
            duration: CMTimeCode(clip.duration),
            timelineStart: CMTimeCode(clip.timelineStart),
            opacity: clip.opacity,
            effects: clip.effects,
            transition: clip.transition.map(TransitionDoc.init(transition:)),
            volumeEnvelope: clip.volumeEnvelope,
            speedCurve: clip.speedCurve,
            preservePitch: clip.preservePitch,
            pitchAlgorithm: clip.pitchAlgorithm)
    }
}

extension TransitionDoc {
    public init(transition: Transition) {
        self.init(type: transition.type.rawValue,
                  duration: CMTimeCode(transition.duration),
                  wipeAngle: transition.wipeAngle)
    }
}

// MARK: - Overlay clip persistence

public struct OverlayClipDoc: Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceType: OverlaySourceType
    public var bookmark: Data
    public var bundleRelativePath: String?
    public var timelineStart: CMTimeCode
    public var duration: CMTimeCode
    public var positionOffsetX: Double
    public var positionOffsetY: Double
    public var scale: Double
    public var rotation: Double
    public var opacity: Float
    public var endAction: OverlayEndAction

    public init(id: UUID = UUID(),
                sourceType: OverlaySourceType,
                bookmark: Data,
                bundleRelativePath: String? = nil,
                timelineStart: CMTimeCode,
                duration: CMTimeCode,
                positionOffsetX: Double = 0,
                positionOffsetY: Double = 0,
                scale: Double = 1,
                rotation: Double = 0,
                opacity: Float = 1,
                endAction: OverlayEndAction = .loop) {
        self.id = id
        self.sourceType = sourceType
        self.bookmark = bookmark
        self.bundleRelativePath = bundleRelativePath
        self.timelineStart = timelineStart
        self.duration = duration
        self.positionOffsetX = positionOffsetX
        self.positionOffsetY = positionOffsetY
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.endAction = endAction
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceType, bookmark, bundleRelativePath, timelineStart, duration,
             positionOffsetX, positionOffsetY, scale, rotation, opacity, endAction
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceType = try c.decode(OverlaySourceType.self, forKey: .sourceType)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark) ?? Data()
        bundleRelativePath = try c.decodeIfPresent(String.self, forKey: .bundleRelativePath)
        timelineStart = try c.decode(CMTimeCode.self, forKey: .timelineStart)
        duration = try c.decode(CMTimeCode.self, forKey: .duration)
        positionOffsetX = try c.decodeIfPresent(Double.self, forKey: .positionOffsetX) ?? 0
        positionOffsetY = try c.decodeIfPresent(Double.self, forKey: .positionOffsetY) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        endAction = try c.decodeIfPresent(OverlayEndAction.self, forKey: .endAction) ?? .loop
    }

    public func makeOverlayClip() -> OverlayClip {
        OverlayClip(
            id: id,
            sourceType: sourceType,
            timelineStart: timelineStart.cmTime,
            duration: duration.cmTime,
            positionOffset: CGSize(width: positionOffsetX, height: positionOffsetY),
            scale: scale,
            rotation: rotation,
            opacity: opacity,
            endAction: endAction)
    }
}

extension OverlayClipDoc {
    public init(overlay: OverlayClip, bookmark: Data, bundleRelativePath: String? = nil) {
        self.init(
            id: overlay.id,
            sourceType: overlay.sourceType,
            bookmark: bookmark,
            bundleRelativePath: bundleRelativePath,
            timelineStart: CMTimeCode(overlay.timelineStart),
            duration: CMTimeCode(overlay.duration),
            positionOffsetX: overlay.positionOffset.width,
            positionOffsetY: overlay.positionOffset.height,
            scale: overlay.scale,
            rotation: overlay.rotation,
            opacity: overlay.opacity,
            endAction: overlay.endAction)
    }
}
