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

enum SafeZoneLibrary {
    static let defaultProfileID = "tiktok"

    static var builtInProfiles: [SafeZoneProfile] {
        [
            verticalProfile(
                id: "douyin",
                name: "Douyin",
                sourceName: "Douyin creator guidance",
                sourceURL: nil,
                regions: commonVerticalRegions()),
            SafeZoneProfile(
                schemaVersion: 1,
                platformID: "xiaohongshu-square",
                displayName: "Xiaohongshu 1:1",
                aspect: .square1x1,
                sourceName: "Xiaohongshu creator guidance",
                sourceURL: nil,
                validatedAt: "2026-06-25",
                regions: [
                    rect(id: "caption-band", x: 0.08, y: 0.78, width: 0.84, height: 0.16),
                    rect(id: "right-actions", x: 0.86, y: 0.42, width: 0.11, height: 0.36),
                ]),
            SafeZoneProfile(
                schemaVersion: 1,
                platformID: "xiaohongshu-portrait",
                displayName: "Xiaohongshu 4:5",
                aspect: .portrait4x5,
                sourceName: "Xiaohongshu creator guidance",
                sourceURL: nil,
                validatedAt: "2026-06-25",
                regions: [
                    rect(id: "top-title", x: 0, y: 0, width: 1, height: 0.10),
                    rect(id: "caption-band", x: 0.08, y: 0.80, width: 0.84, height: 0.14),
                    rect(id: "right-actions", x: 0.86, y: 0.46, width: 0.11, height: 0.34),
                ]),
            verticalProfile(
                id: "youtube-shorts",
                name: "YouTube Shorts",
                sourceName: "YouTube Help",
                sourceURL: "https://support.google.com/youtube/answer/6375112",
                regions: commonVerticalRegions()),
            verticalProfile(
                id: "instagram-reels",
                name: "Instagram Reels",
                sourceName: "Meta creator guidance",
                sourceURL: nil,
                regions: commonVerticalRegions()),
            verticalProfile(
                id: "tiktok",
                name: "TikTok",
                sourceName: "TikTok Business Help Center",
                sourceURL: "https://ads.tiktok.com/help/article/tiktok-auction-in-feed-ads",
                regions: commonVerticalRegions()),
        ]
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

    private static func verticalProfile(id: String,
                                        name: String,
                                        sourceName: String,
                                        sourceURL: String?,
                                        regions: [SafeZoneRegion]) -> SafeZoneProfile {
        SafeZoneProfile(
            schemaVersion: 1,
            platformID: id,
            displayName: name,
            aspect: .vertical9x16,
            sourceName: sourceName,
            sourceURL: sourceURL,
            validatedAt: "2026-06-25",
            regions: regions)
    }

    private static func commonVerticalRegions() -> [SafeZoneRegion] {
        [
            rect(id: "top-chrome", x: 0, y: 0, width: 1, height: 0.09),
            rect(id: "bottom-caption", x: 0.06, y: 0.78, width: 0.78, height: 0.17),
            rect(id: "right-actions", x: 0.84, y: 0.48, width: 0.14, height: 0.40),
        ]
    }

    private static func rect(id: String, x: Double, y: Double,
                             width: Double, height: Double) -> SafeZoneRegion {
        SafeZoneRegion(
            id: id,
            kind: "occlusion",
            points: [
                SafeZonePoint(x: x, y: y),
                SafeZonePoint(x: x + width, y: y),
                SafeZonePoint(x: x + width, y: y + height),
                SafeZonePoint(x: x, y: y + height),
            ])
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
