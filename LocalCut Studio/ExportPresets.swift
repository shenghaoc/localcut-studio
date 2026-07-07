import Foundation
import AVFoundation
import LocalCutCore
import CoreGraphics
import CoreMedia
import AudioToolbox

// MARK: - Aspect / bitrate / audio descriptors

/// Aspect-ratio identifier for an export preset. The render queue uses this to
/// choose an `AVAssetExportSession` preset name where possible, and to keep
/// 9:16 / 1:1 / 4:5 jobs visibly distinct in the inspector list.
nonisolated enum ExportAspect: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case widescreen     // 16:9
    case vertical       // 9:16
    case square         // 1:1
    case portrait4x5    // 4:5
    case cinema21x9     // 21:9

    var id: String { rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .widescreen
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .widescreen: "16:9"
        case .vertical: "9:16"
        case .square: "1:1"
        case .portrait4x5: "4:5"
        case .cinema21x9: "21:9"
        }
    }
}

/// Coarse bitrate bracket. The queue's `AVAssetWriter` fallback turns this into
/// a concrete bits-per-second target via `bitsPerSecond(for:)`; the
/// `AVAssetExportSession` path leans on Apple's tuned defaults for the chosen
/// preset name instead.
nonisolated enum ExportBitrateBracket: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case low, standard, high, max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .standard: "Standard"
        case .high: "High"
        case .max: "Max"
        }
    }

    /// Rough per-pixel rate used by the writer fallback. The bracket
    /// multiplies a baseline of ~0.1 bits per pixel per second. Frame rate is
    /// part of the budget — a 60 fps render at the same bracket as a 30 fps
    /// render gets twice the bitrate (Claude review). Uses `Swift.max` to
    /// disambiguate against the `.max` enum case while inside this enum's
    /// scope.
    func bitsPerSecond(for renderSize: CGSize, frameRate: Double) -> Int {
        let area = Swift.max(1.0, Double(renderSize.width) * Double(renderSize.height))
        let pixelsPerSecond = area * Swift.max(1, frameRate)
        let perPixel: Double
        switch self {
        case .low: perPixel = 0.05
        case .standard: perPixel = 0.10
        case .high: perPixel = 0.18
        case .max: perPixel = 0.30
        }
        return Int(pixelsPerSecond * perPixel)
    }
}

/// Audio output knobs shared across every export. Stored as raw codec / format
/// IDs so the value Codable-round-trips without depending on AudioToolbox enum
/// surface.
nonisolated struct AudioConfig: Codable, Hashable, Sendable {
    /// `AudioFormatID` raw value, e.g. `kAudioFormatMPEG4AAC` or
    /// `kAudioFormatLinearPCM`.
    var codec: UInt32
    /// Bits per second target for compressed audio; ignored for LPCM.
    var bitrate: Int
    /// Sample rate in Hz.
    var sampleRate: Int
    /// 1 = mono, 2 = stereo.
    var channels: Int

    static let aac192k = AudioConfig(codec: kAudioFormatMPEG4AAC, bitrate: 192_000, sampleRate: 48_000, channels: 2)
    static let aac256k = AudioConfig(codec: kAudioFormatMPEG4AAC, bitrate: 256_000, sampleRate: 48_000, channels: 2)
    static let aac128k = AudioConfig(codec: kAudioFormatMPEG4AAC, bitrate: 128_000, sampleRate: 48_000, channels: 2)
    static let lpcm48k = AudioConfig(codec: kAudioFormatLinearPCM, bitrate: 0, sampleRate: 48_000, channels: 2)
}

// MARK: - Codable CGSize wrapper

/// Codable wrapper for `CGSize` so an `ExportPreset` round-trips through JSON
/// without dragging the runtime `CGSize` (which conforms to Codable through
/// CoreGraphics but emits unkeyed pairs that are awkward to hand-author).
nonisolated struct ExportSize: Codable, Hashable, Sendable {
    var width: Double
    var height: Double

    init(_ size: CGSize) {
        self.width = Double(size.width)
        self.height = Double(size.height)
    }

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    var cgSize: CGSize { CGSize(width: width, height: height) }
}

// MARK: - Platform finishing metadata

nonisolated struct PlatformExportMetadata: Codable, Hashable, Sendable {
    var platformID: String
    var displayName: String
    var safeZoneProfileID: String?
    var loudnessTargetLUFS: Double?
    var guidanceSourceName: String?
    var guidanceSourceURL: String?
    var guidanceValidatedAt: String?

    init(platformID: String,
         displayName: String,
         safeZoneProfileID: String? = nil,
         loudnessTargetLUFS: Double? = -14,
         guidanceSourceName: String? = nil,
         guidanceSourceURL: String? = nil,
         guidanceValidatedAt: String? = nil) {
        self.platformID = platformID
        self.displayName = displayName
        self.safeZoneProfileID = safeZoneProfileID
        self.loudnessTargetLUFS = loudnessTargetLUFS
        self.guidanceSourceName = guidanceSourceName
        self.guidanceSourceURL = guidanceSourceURL
        self.guidanceValidatedAt = guidanceValidatedAt
    }
}

// MARK: - ExportPreset

/// One vetted output recipe: container × video codec × aspect × pixel
/// dimensions × bitrate bracket × audio. The render queue consumes presets
/// directly; the inspector lists `BuiltInExportPresets.all` next to "Add to
/// Queue" buttons.
///
/// Stored on disk inside `QueueJob`, so every field is Codable and Sendable.
nonisolated struct ExportPreset: Codable, Hashable, Sendable, Identifiable {
    /// Stable id so a job referring back to its preset by id keeps working
    /// across encode / decode cycles.
    let id: UUID

    /// User-visible name. Two presets may share a name only if they differ on
    /// something else (codec / size) — the inspector uses it directly in the
    /// list and in save-panel filenames.
    var name: String

    /// `AVFileType.rawValue` — `com.apple.quicktime-movie` for `.mov`,
    /// `public.mpeg-4` for `.mp4`, `com.apple.m4v-video` for `.m4v`.
    var containerFormat: String

    /// `AVVideoCodecType.rawValue` — `avc1` (h264), `hvc1` (hevc),
    /// `apch` (ProRes 422 HQ), etc.
    var videoCodec: String

    var aspect: ExportAspect
    var targetSize: ExportSize
    var bitrate: ExportBitrateBracket

    /// `nil` ⇒ inherit the project's frame rate at render time.
    var frameRate: Double?

    var audioConfig: AudioConfig
    var platformMetadata: PlatformExportMetadata?

    init(id: UUID = UUID(),
         name: String,
         containerFormat: String,
         videoCodec: String,
         aspect: ExportAspect,
         targetSize: CGSize,
         bitrate: ExportBitrateBracket,
         frameRate: Double? = nil,
         audioConfig: AudioConfig,
         platformMetadata: PlatformExportMetadata? = nil) {
        self.id = id
        self.name = name
        self.containerFormat = containerFormat
        self.videoCodec = videoCodec
        self.aspect = aspect
        self.targetSize = ExportSize(targetSize)
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.audioConfig = audioConfig
        self.platformMetadata = platformMetadata
    }

    /// Convenience accessor for the typed `AVFileType`. Always synthesised
    /// from the stored raw value so a hand-edited preset can't fall out of
    /// sync.
    var containerType: AVFileType { AVFileType(rawValue: containerFormat) }

    /// Convenience accessor for the typed `AVVideoCodecType`.
    var codecType: AVVideoCodecType { AVVideoCodecType(rawValue: videoCodec) }

    /// Default extension used when constructing the save-panel filename.
    var defaultFilenameExtension: String {
        switch containerFormat {
        case AVFileType.mov.rawValue: "mov"
        case AVFileType.mp4.rawValue: "mp4"
        case AVFileType.m4v.rawValue: "m4v"
        default: "mov"
        }
    }
}

// MARK: - Codec × container validity

extension ExportPreset {

    /// Allow-list of supported `(container, codec)` pairs. Outside this set,
    /// AVFoundation's writer refuses to mux; the queue rejects such jobs at
    /// enqueue rather than letting them fail mid-encode.
    static func isSupportedCombination(container: String, codec: String) -> Bool {
        let pair = (container, codec)
        return supportedPairs.contains { $0 == pair }
    }

    /// Same gate using typed enums.
    static func isSupportedCombination(container: AVFileType, codec: AVVideoCodecType) -> Bool {
        isSupportedCombination(container: container.rawValue, codec: codec.rawValue)
    }

    /// Static list rather than a `Set` so equality is by `(String, String)`
    /// pairs (Set requires Hashable on tuples, which Swift doesn't synthesise).
    /// The list is small enough that linear scan is a non-issue.
    private static let supportedPairs: [(String, String)] = {
        let mov = AVFileType.mov.rawValue
        let mp4 = AVFileType.mp4.rawValue
        let m4v = AVFileType.m4v.rawValue
        return [
            (mov, AVVideoCodecType.h264.rawValue),
            (mov, AVVideoCodecType.hevc.rawValue),
            (mov, AVVideoCodecType.proRes422.rawValue),
            (mov, AVVideoCodecType.proRes422HQ.rawValue),
            (mov, AVVideoCodecType.proRes422LT.rawValue),
            (mov, AVVideoCodecType.proRes422Proxy.rawValue),
            (mov, AVVideoCodecType.proRes4444.rawValue),
            (mp4, AVVideoCodecType.h264.rawValue),
            (mp4, AVVideoCodecType.hevc.rawValue),
            (m4v, AVVideoCodecType.h264.rawValue),
            (m4v, AVVideoCodecType.hevc.rawValue),
        ]
    }()

    // MARK: - Host capability validation

    /// Returns `true` when HEVC video encoding is available on this Mac.
    /// Checks `AVAssetExportSession` preset availability — if the HEVC 1920×1080
    /// preset is listed, the hardware + software stack supports HEVC output.
    static let isHEVCEncodingAvailable: Bool = {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVC1920x1080)
    }()

    /// Returns any host-capability error for this preset beyond the
    /// container/codec allow-list. Returns `nil` if the preset is usable.
    func hostCapabilityError() -> String? {
        if videoCodec == AVVideoCodecType.hevc.rawValue,
           !Self.isHEVCEncodingAvailable {
            return "HEVC encoding is not available on this Mac."
        }
        // ProRes 4444 requires hardware support that may not be available
        // on all Macs. The writer fallback path will attempt the encode,
        // but warn the user if the codec is unlikely to work.
        if videoCodec == AVVideoCodecType.proRes4444.rawValue {
            // ProRes 4444 encoding is generally available on Apple Silicon
            // and recent Intel Macs, but we can't reliably detect it without
            // attempting the encode. Log a note for diagnostics.
        }
        return nil
    }
}

// MARK: - Built-in library

/// The six presets shipped in-binary. Listed as a static array so the inspector
/// renders them as plain buttons and the test suite exercises every entry
/// against `isSupportedCombination`.
nonisolated enum BuiltInExportPresets {

    static let all: [ExportPreset] = [
        youTube1080p,
        youTube4K,
        youTubeShorts,
        douyinVertical,
        xiaohongshuSquare,
        xiaohongshuPortrait,
        instagramVertical,
        tikTokVertical,
        proRes4K,
        web720p,
    ]

    /// The preset the toolbar/menu Export shortcut enqueues. Currently
    /// "YouTube 1080p" — the most common request for a non-vertical render.
    static var defaultPreset: ExportPreset { youTube1080p }

    /// Look up a preset by id. Used by the queue when a row needs to redraw
    /// the matching built-in entry.
    static func preset(id: UUID) -> ExportPreset? {
        all.first { $0.id == id }
    }

    // Stable, deterministic ids so persisted queue jobs carrying the built-in
    // preset value continue to compare equal across launches.
    private static let youTube1080pID  = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let youTube4KID     = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let instagramID     = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let tikTokID        = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let proRes4KID      = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private static let web720pID       = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private static let youTubeShortsID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private static let douyinID        = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private static let xhsSquareID     = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private static let xhsPortraitID   = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    static let youTube1080p = ExportPreset(
        id: youTube1080pID,
        name: "YouTube 1080p",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .widescreen,
        targetSize: CGSize(width: 1920, height: 1080),
        bitrate: .standard,
        frameRate: nil,
        audioConfig: .aac192k,
        platformMetadata: PlatformExportMetadata(
            platformID: "youtube",
            displayName: "YouTube",
            safeZoneProfileID: nil,
            guidanceSourceName: "YouTube Help",
            guidanceSourceURL: "https://support.google.com/youtube/answer/1722171",
            guidanceValidatedAt: "2026-06-25"))

    static let youTube4K = ExportPreset(
        id: youTube4KID,
        name: "YouTube 4K",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.hevc.rawValue,
        aspect: .widescreen,
        targetSize: CGSize(width: 3840, height: 2160),
        bitrate: .high,
        frameRate: nil,
        audioConfig: .aac256k)

    static let youTubeShorts = ExportPreset(
        id: youTubeShortsID,
        name: "YouTube Shorts 9:16",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .vertical,
        targetSize: CGSize(width: 1080, height: 1920),
        bitrate: .standard,
        frameRate: nil,
        audioConfig: .aac128k,
        platformMetadata: PlatformExportMetadata(
            platformID: "youtube-shorts",
            displayName: "YouTube Shorts",
            safeZoneProfileID: "youtube-shorts",
            guidanceSourceName: "YouTube Help",
            guidanceSourceURL: "https://support.google.com/youtube/answer/6375112",
            guidanceValidatedAt: "2026-06-25"))

    static let douyinVertical = ExportPreset(
        id: douyinID,
        name: "Douyin 9:16",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .vertical,
        targetSize: CGSize(width: 1080, height: 1920),
        bitrate: .standard,
        frameRate: nil,
        audioConfig: .aac128k,
        platformMetadata: PlatformExportMetadata(
            platformID: "douyin",
            displayName: "Douyin",
            safeZoneProfileID: "douyin",
            guidanceSourceName: "Douyin creator guidance",
            guidanceValidatedAt: "2026-06-25"))

    static let xiaohongshuSquare = ExportPreset(
        id: xhsSquareID,
        name: "Xiaohongshu 1:1",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .square,
        targetSize: CGSize(width: 1080, height: 1080),
        bitrate: .standard,
        frameRate: nil,
        audioConfig: .aac128k,
        platformMetadata: PlatformExportMetadata(
            platformID: "xiaohongshu",
            displayName: "Xiaohongshu",
            safeZoneProfileID: "xiaohongshu-square",
            guidanceSourceName: "Xiaohongshu creator guidance",
            guidanceValidatedAt: "2026-06-25"))

    static let xiaohongshuPortrait = ExportPreset(
        id: xhsPortraitID,
        name: "Xiaohongshu 4:5",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .portrait4x5,
        targetSize: CGSize(width: 1080, height: 1350),
        bitrate: .standard,
        frameRate: nil,
        audioConfig: .aac128k,
        platformMetadata: PlatformExportMetadata(
            platformID: "xiaohongshu",
            displayName: "Xiaohongshu",
            safeZoneProfileID: "xiaohongshu-portrait",
            guidanceSourceName: "Xiaohongshu creator guidance",
            guidanceValidatedAt: "2026-06-25"))

    static let instagramVertical = ExportPreset(
        id: instagramID,
        name: "Instagram 9:16",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .vertical,
        targetSize: CGSize(width: 1080, height: 1920),
        bitrate: .standard,
        frameRate: nil,
        audioConfig: .aac128k,
        platformMetadata: PlatformExportMetadata(
            platformID: "instagram-reels",
            displayName: "Instagram Reels",
            safeZoneProfileID: "instagram-reels",
            guidanceSourceName: "Meta creator guidance",
            guidanceValidatedAt: "2026-06-25"))

    static let tikTokVertical = ExportPreset(
        id: tikTokID,
        name: "TikTok 9:16",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .vertical,
        targetSize: CGSize(width: 1080, height: 1920),
        bitrate: .standard,
        frameRate: nil,
        audioConfig: .aac128k,
        platformMetadata: PlatformExportMetadata(
            platformID: "tiktok",
            displayName: "TikTok",
            safeZoneProfileID: "tiktok",
            guidanceSourceName: "TikTok Business Help Center",
            guidanceSourceURL: "https://ads.tiktok.com/help/article/tiktok-auction-in-feed-ads",
            guidanceValidatedAt: "2026-06-25"))

    static let proRes4K = ExportPreset(
        id: proRes4KID,
        name: "ProRes 4K",
        containerFormat: AVFileType.mov.rawValue,
        videoCodec: AVVideoCodecType.proRes422HQ.rawValue,
        aspect: .widescreen,
        targetSize: CGSize(width: 3840, height: 2160),
        bitrate: .max,
        frameRate: nil,
        audioConfig: .lpcm48k)

    static let web720p = ExportPreset(
        id: web720pID,
        name: "Web 720p",
        containerFormat: AVFileType.mp4.rawValue,
        videoCodec: AVVideoCodecType.h264.rawValue,
        aspect: .widescreen,
        targetSize: CGSize(width: 1280, height: 720),
        bitrate: .low,
        frameRate: nil,
        audioConfig: .aac128k)
}

// MARK: - AVAssetExportSession preset mapping

extension ExportPreset {

    var projectAspect: ProjectAspect {
        switch aspect {
        case .widescreen: .widescreen16x9
        case .vertical: .vertical9x16
        case .square: .square1x1
        case .portrait4x5: .portrait4x5
        case .cinema21x9: .custom
        }
    }

    /// Maps the recipe onto an `AVAssetExportSession` preset name when one
    /// exists. The render queue falls back to the `AVAssetWriter` path when
    /// this returns `nil`.
    ///
    /// The matrix is intentionally conservative — Apple's preset constants are
    /// the only combinations guaranteed to encode without further tuning, so
    /// we only return one when the (codec, size, bracket) tuple maps cleanly.
    var assetExportSessionPresetName: String? {
        let h264 = AVVideoCodecType.h264.rawValue
        let hevc = AVVideoCodecType.hevc.rawValue
        let proRes422 = AVVideoCodecType.proRes422.rawValue
        let proRes4444 = AVVideoCodecType.proRes4444.rawValue

        let width = Int(targetSize.width)
        let height = Int(targetSize.height)

        switch videoCodec {
        case h264:
            if matches(width, height, 1280, 720) { return AVAssetExportPreset1280x720 }
            if matches(width, height, 1920, 1080) { return AVAssetExportPreset1920x1080 }
            if matches(width, height, 3840, 2160) { return AVAssetExportPreset3840x2160 }
        case hevc:
            if matches(width, height, 1920, 1080) { return AVAssetExportPresetHEVC1920x1080 }
            if matches(width, height, 3840, 2160) { return AVAssetExportPresetHEVC3840x2160 }
        case proRes422:
            return AVAssetExportPresetAppleProRes422LPCM
        case proRes4444:
            return AVAssetExportPresetAppleProRes4444LPCM
        // Other ProRes flavours (HQ, LT, Proxy) intentionally fall through to
        // the AVAssetWriter path: AVFoundation's session presets don't expose
        // a HQ/LT/Proxy variant, and mapping them to the plain 422 preset
        // would silently downgrade the encoded file while the inspector still
        // advertises the higher-quality codec.
        default:
            return nil
        }
        return nil
    }

    /// Only matches the canonical landscape orientation. Vertical / square /
    /// other-aspect renders return `nil` from `assetExportSessionPresetName`
    /// and fall through to the `AVAssetWriter` path, which honours any
    /// render size; the orientation-flip branch (`aw == bh && ah == bw`)
    /// would otherwise route a 1080×1920 Instagram preset through
    /// `AVAssetExportPreset1920x1080`, whose vertical output depends on
    /// undocumented session behaviour that varies across macOS versions
    /// (Claude review).
    private func matches(_ aw: Int, _ ah: Int, _ bw: Int, _ bh: Int) -> Bool {
        aw == bw && ah == bh
    }
}
