import Foundation
import Observation
import Security

nonisolated enum PublishEndpointType: String, Hashable, Sendable, CaseIterable, Identifiable {
    case twitch, cloudflare, mediaMTX, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .twitch: "Twitch"
        case .cloudflare: "Cloudflare Stream"
        case .mediaMTX: "MediaMTX"
        case .custom: "Custom"
        }
    }
    var defaultEndpointURL: String {
        switch self {
        case .twitch: "https://g.webrtc.live-video.net:443/v1/offer"
        case .cloudflare: "https://customer.cloudflarestream.com/whip"
        case .mediaMTX: "http://localhost:8889/stream/whip"
        case .custom: ""
        }
    }
    var requiresToken: Bool {
        switch self {
        case .twitch, .cloudflare: true
        case .mediaMTX, .custom: false
        }
    }
}

@Observable
@MainActor
final class PublishSettings {
    var endpointURL: String {
        didSet { UserDefaults.standard.set(endpointURL, forKey: Keys.endpointURL) }
    }
    var endpointType: PublishEndpointType {
        didSet { UserDefaults.standard.set(endpointType.rawValue, forKey: Keys.endpointType) }
    }
    var rememberToken: Bool {
        didSet {
            UserDefaults.standard.set(rememberToken, forKey: Keys.rememberToken)
            if rememberToken { saveTokenToKeychain() } else { removeTokenFromKeychain() }
        }
    }
    var bearerToken: String?

    init() {
        let defaults = UserDefaults.standard
        let savedType = defaults.string(forKey: Keys.endpointType)
            .flatMap(PublishEndpointType.init(rawValue:)) ?? .twitch
        self.endpointType = savedType
        self.endpointURL = defaults.string(forKey: Keys.endpointURL) ?? savedType.defaultEndpointURL
        self.rememberToken = defaults.bool(forKey: Keys.rememberToken)
        if rememberToken { self.bearerToken = KeychainHelper.load(key: keychainKey) }
    }

    func tokenForCurrentEndpoint() -> String? {
        guard endpointType.requiresToken else { return nil }
        if rememberToken { return KeychainHelper.load(key: keychainKey) ?? bearerToken }
        return bearerToken
    }

    func saveTokenToKeychain() {
        guard endpointType.requiresToken else { return }
        guard let token = bearerToken, !token.isEmpty else { return }
        KeychainHelper.save(key: keychainKey, data: token)
    }

    func removeTokenFromKeychain() { KeychainHelper.delete(key: keychainKey) }

    func redactedTokenDisplay() -> String {
        guard endpointType.requiresToken else { return "" }
        guard let token = bearerToken, !token.isEmpty else { return "" }
        return "••••••"
    }

    private enum Keys {
        static let endpointURL = "publish.endpointURL"
        static let endpointType = "publish.endpointType"
        static let rememberToken = "publish.rememberToken"
    }

    private var keychainKey: String {
        let base = "com.localcut.studio.publish.\(endpointType.rawValue)"
        let hash = endpointURL.utf8.reduce(0) { ($0 &* 31 &+ UInt($1)) & 0xFFFF }
        return "\(base).\(String(hash, radix: 16))"
    }
}
