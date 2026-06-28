import Foundation
import CoreGraphics
import LocalCutCore

struct SafeZonePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct SafeZoneRegion: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var points: [SafeZonePoint]
}

struct SafeZoneProfile: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion: Int
    var platformID: String
    var displayName: String
    var aspect: ProjectAspect
    var sourceName: String
    var sourceURL: String?
    var validatedAt: String
    var regions: [SafeZoneRegion]

    var id: String { platformID }

    func validationErrors() -> [String] {
        var errors: [String] = []
        if schemaVersion != 1 { errors.append("schemaVersion must be 1") }
        if platformID.isEmpty { errors.append("platformID is required") }
        if displayName.isEmpty { errors.append("displayName is required") }
        if sourceName.isEmpty { errors.append("sourceName is required") }
        if regions.isEmpty { errors.append("at least one region is required") }

        var ids = Set<String>()
        for region in regions {
            if region.id.isEmpty { errors.append("region id is required") }
            if !ids.insert(region.id).inserted {
                errors.append("duplicate region id \(region.id)")
            }
            if region.points.count < 3 {
                errors.append("region \(region.id) needs at least three points")
            }
            for point in region.points {
                if !(0.0...1.0).contains(point.x) || !(0.0...1.0).contains(point.y) {
                    errors.append("region \(region.id) has an out-of-range point")
                }
            }
        }
        return errors
    }
}

@MainActor
enum SafeZoneLibrary {
    static let defaultProfileID = "tiktok"

    /// Tracks whether bundled JSON profiles failed to load or validate so the
    /// caller can surface errors through `statusMessage`.
    static private(set) var loadErrors: [String] = []

    /// Cached profiles — loaded once from bundle JSON on first access, then
    /// reused. The bundle resources never change at runtime.
    private static var _cachedProfiles: [SafeZoneProfile]?

    /// Loads profiles from bundled JSON resources. Surface errors via
    /// `loadErrors` so the app can show `statusMessage` without crashing
    /// preview or export.
    static var builtInProfiles: [SafeZoneProfile] {
        if let cached = _cachedProfiles { return cached }
        let loaded = loadFromBundle()
        _cachedProfiles = loaded
        return loaded
    }

    static func profile(id: String) -> SafeZoneProfile? {
        builtInProfiles.first { $0.platformID == id }
    }

    static func validProfile(id: String, for aspect: ProjectAspect) -> SafeZoneProfile? {
        guard let profile = profile(id: id),
              profile.aspect == aspect,
              profile.validationErrors().isEmpty else { return nil }
        return profile
    }

    // MARK: - JSON loading

    /// Loads every safe-zone `*.json`, decodes, validates. Xcode's synchronized
    /// groups flatten these resources into the app bundle root today, while
    /// older/manual resource phases may preserve `SafeZones/`.
    /// Profiles that fail to load or validate are dropped and an error is
    /// appended to `loadErrors`.
    private static func loadFromBundle() -> [SafeZoneProfile] {
        let urls = bundledProfileURLs()
        guard !urls.isEmpty else {
            Self.loadErrors = ["Safe zone directory not found in bundle resources."]
            return []
        }
        var profiles: [SafeZoneProfile] = []
        let filenames = Set(urls.map(\.lastPathComponent))
        var newErrors = Self.profileResourceFilenames
            .subtracting(filenames)
            .sorted()
            .map { "Safe-zone file \($0) is missing from bundle resources." }
        for url in urls {
            let filename = url.lastPathComponent
            guard filename != Self.schemaFilename else { continue }
            guard let data = try? Data(contentsOf: url) else {
                newErrors.append("Could not read safe-zone file \(filename).")
                continue
            }
            let decoder = JSONDecoder()
            guard let profile = try? decoder.decode(SafeZoneProfile.self, from: data) else {
                newErrors.append("Safe-zone file \(filename) is malformed JSON.")
                continue
            }
            let validationErrors = profile.validationErrors()
            if !validationErrors.isEmpty {
                newErrors.append("Safe-zone profile \(filename) has validation errors: \(validationErrors.joined(separator: "; ")).")
                continue
            }
            profiles.append(profile)
        }
        if newErrors.isEmpty, profiles.isEmpty {
            newErrors.append("No safe-zone profiles loaded from bundle resources.")
        }
        Self.loadErrors = newErrors
        return profiles
    }

    private static func bundledProfileURLs() -> [URL] {
        for subdirectory in ["SafeZones", "Resources/SafeZones"] {
            let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                        subdirectory: subdirectory) ?? []
            let profileURLs = urls.filter { Self.allSafeZoneResourceFilenames.contains($0.lastPathComponent) }
            if !profileURLs.isEmpty { return profileURLs }
        }
        let rootURLs = Bundle.main.urls(forResourcesWithExtension: "json",
                                        subdirectory: nil) ?? []
        return rootURLs.filter { Self.allSafeZoneResourceFilenames.contains($0.lastPathComponent) }
    }

    private static let schemaFilename = "safe-zones-v1.schema.json"

    private static let profileResourceFilenames: Set<String> = [
        "douyin.json",
        "instagram-reels.json",
        "tiktok.json",
        "xiaohongshu-portrait.json",
        "xiaohongshu-square.json",
        "youtube-shorts.json",
    ]

    private static var allSafeZoneResourceFilenames: Set<String> {
        profileResourceFilenames.union([schemaFilename])
    }
}

enum PreviewCanvasGeometry {
    static func canvasRect(container: CGSize, renderSize: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0,
              renderSize.width > 0, renderSize.height > 0 else {
            return .zero
        }
        let scale = min(container.width / renderSize.width,
                        container.height / renderSize.height)
        let width = renderSize.width * scale
        let height = renderSize.height * scale
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height)
    }

    static func point(_ point: SafeZonePoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * point.y)
    }
}
