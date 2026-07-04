import Foundation
#if arch(arm64)
import VideoToolbox
#endif

nonisolated enum PublishCodec: String, Hashable, Sendable, CaseIterable, Identifiable {
    case h264Baseline, av1
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .h264Baseline: "H.264 Baseline"
        case .av1: "AV1"
        }
    }
    var sdpProfileLevelID: String? {
        switch self {
        case .h264Baseline: "42e029"
        case .av1: nil
        }
    }
}

nonisolated struct PublishProfile: Hashable, Sendable {
    let codec: PublishCodec
    let videoBitrate: Int
    let audioBitrate: Int
    let keyframeInterval: Int
    let maxKeyframeInterval: Int

    init(codec: PublishCodec, videoBitrate: Int, audioBitrate: Int, keyframeInterval: Int, maxKeyframeInterval: Int) {
        self.codec = codec
        self.videoBitrate = max(100_000, min(videoBitrate, 50_000_000))
        self.audioBitrate = max(16_000, min(audioBitrate, 512_000))
        self.keyframeInterval = max(1, min(keyframeInterval, 10))
        self.maxKeyframeInterval = max(keyframeInterval, min(maxKeyframeInterval, 10))
    }
}

nonisolated enum PublishEndpointDefaults {
    static let twitch = PublishProfile(codec: .h264Baseline, videoBitrate: 6_000_000, audioBitrate: 128_000, keyframeInterval: 2, maxKeyframeInterval: 2)
    static let cloudflare = PublishProfile(codec: .h264Baseline, videoBitrate: 6_000_000, audioBitrate: 128_000, keyframeInterval: 2, maxKeyframeInterval: 2)
    static let mediaMTX = PublishProfile(codec: .h264Baseline, videoBitrate: 4_000_000, audioBitrate: 128_000, keyframeInterval: 2, maxKeyframeInterval: 2)
    static let custom = PublishProfile(codec: .h264Baseline, videoBitrate: 4_000_000, audioBitrate: 128_000, keyframeInterval: 2, maxKeyframeInterval: 2)
    static func `default`(for endpointType: PublishEndpointType) -> PublishProfile {
        switch endpointType {
        case .twitch: twitch
        case .cloudflare: cloudflare
        case .mediaMTX: mediaMTX
        case .custom: custom
        }
    }
}

nonisolated enum PublishCodecProber {
    static var isAV1EncodeAvailable: Bool {
        #if arch(arm64)
        return probeForAV1Encoder()
        #else
        return false
        #endif
    }
    static func isAV1Available(for endpointType: PublishEndpointType) -> Bool {
        guard isAV1EncodeAvailable else { return false }
        return endpointType == .cloudflare
    }
    #if arch(arm64)
    private static func probeForAV1Encoder() -> Bool {
        var listRef: CFArray?
        let status = VTCopyVideoEncoderList(nil, &listRef)
        guard status == noErr, let list = listRef else { return false }
        guard let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains { entry in
            if let codecType = entry["CodecType"] as? FourCharCode, codecType == 0x6176_3031 { return true }
            if let name = entry["DisplayName"] as? String { return name.localizedCaseInsensitiveContains("AV1") }
            return false
        }
    }
    #endif
}
