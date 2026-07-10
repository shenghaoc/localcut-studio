import Testing
import Foundation
import CoreGraphics
import CoreMedia
import AVFoundation
import UniformTypeIdentifiers
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Phase 39 vertical finishing")
struct Phase39Tests {
    @Test("ProjectDocument round-trips aspect and cover frame")
    func documentRoundTripsAspectAndCover() throws {
        let cover = CoverFrameDoc(
            time: CMTimeCode(CMTime(seconds: 4.2, preferredTimescale: 600)),
            format: .jpeg,
            title: CoverTitleDoc(text: "Launch"),
            bundleRelativePath: "covers/test.jpg")
        let document = ProjectDocument(
            name: "Vertical",
            renderWidth: 1080,
            renderHeight: 1920,
            frameRate: 30,
            media: [],
            videoTracks: [],
            audioTracks: [],
            aspect: .vertical9x16,
            coverFrame: cover)

        let decoded = try ProjectDocument(data: document.encoded())

        #expect(decoded.aspect == .vertical9x16)
        #expect(decoded.coverFrame == cover)
        #expect(decoded.coverFrame?.title?.text == "Launch")
    }

    @Test("Legacy documents infer aspect from render size")
    func legacyDocumentInfersAspect() throws {
        let json = """
        {
          "name": "LegacyVertical",
          "renderWidth": 1080,
          "renderHeight": 1920,
          "frameRate": 30,
          "media": [],
          "videoTracks": [],
          "audioTracks": []
        }
        """

        let decoded = try ProjectDocument(data: Data(json.utf8))

        #expect(decoded.aspect == .vertical9x16)
    }

    @Test("Unknown aspect raw value falls back to inference instead of failing")
    func decodeUnknownAspectFallsBackToInference() throws {
        let json = """
        {
          "name": "FutureAspect",
          "renderWidth": 1080,
          "renderHeight": 1920,
          "frameRate": 30,
          "media": [],
          "videoTracks": [],
          "audioTracks": [],
          "aspect": "ultrawide21x9"
        }
        """

        let decoded = try ProjectDocument(data: Data(json.utf8))

        #expect(decoded.aspect == .vertical9x16)
    }

    @Test("Malformed cover frame drops to nil without failing the open")
    func decodeMalformedCoverFrameDropsToNil() throws {
        let json = """
        {
          "name": "BadCover",
          "renderWidth": 1920,
          "renderHeight": 1080,
          "frameRate": 30,
          "media": [],
          "videoTracks": [],
          "audioTracks": [],
          "coverFrame": { "format": "png" }
        }
        """

        let decoded = try ProjectDocument(data: Data(json.utf8))

        #expect(decoded.coverFrame == nil)
        #expect(decoded.aspect == .widescreen16x9)
    }

    @Test("Custom aspect and size round-trip")
    func customAspectRoundTrips() throws {
        let document = ProjectDocument(
            name: "Custom",
            renderWidth: 1000,
            renderHeight: 1001,
            frameRate: 30,
            media: [],
            videoTracks: [],
            audioTracks: [],
            aspect: .custom)

        let decoded = try ProjectDocument(data: document.encoded())

        #expect(decoded.aspect == .custom)
        #expect(decoded.renderWidth == 1000)
        #expect(decoded.renderHeight == 1001)
    }

    @Test("Custom size edits preserve custom aspect and clamp unsafe dimensions")
    func customSizeEditsPreserveCustomAspectAndClamp() {
        let model = EditorModel()

        model.setProjectAspect(.custom)
        model.setRenderSize(CGSize(width: 1000, height: 1001))

        #expect(model.project.aspect == .custom)
        #expect(model.project.renderSize == CGSize(width: 1000, height: 1001))

        model.setRenderSize(CGSize(width: 1.0e20, height: .infinity))

        #expect(model.project.aspect == .custom)
        #expect(model.project.renderSize == CGSize(width: 8192, height: 8192))
    }

    @Test("Cover extraction time snaps to a valid project frame")
    func coverExtractionTimeSnapsToProjectFrame() {
        let snapped = EditorModel.snappedCoverFrameSeconds(
            requested: 1.234,
            duration: 2.0,
            frameRate: 30)
        #expect(abs(snapped - (37.0 / 30.0)) < 0.000_001)

        let endClamped = EditorModel.snappedCoverFrameSeconds(
            requested: 2.0,
            duration: 2.0,
            frameRate: 30)
        #expect(abs(endClamped - (59.0 / 30.0)) < 0.000_001)

        let nonFinite = EditorModel.snappedCoverFrameSeconds(
            requested: .infinity,
            duration: .infinity,
            frameRate: 0)
        #expect(nonFinite == 0)
    }

    @Test("Built-in safe-zone profiles validate")
    func safeZoneProfilesValidate() {
        #expect(SafeZoneLibrary.builtInProfiles.count >= 6)
        #expect(SafeZoneLibrary.loadErrors.isEmpty)
        for profile in SafeZoneLibrary.builtInProfiles {
            #expect(profile.validationErrors().isEmpty,
                    "\(profile.displayName): \(profile.validationErrors().joined(separator: ", "))")
        }
    }

    @Test("Checked-in safe-zone JSON files decode and validate")
    func safeZoneJSONFilesValidate() throws {
        let testURL = URL(filePath: #filePath)
        let repoRoot = testURL.deletingLastPathComponent().deletingLastPathComponent()
        let directory = repoRoot
            .appendingPathComponent("LocalCut Studio")
            .appendingPathComponent("Resources")
            .appendingPathComponent("SafeZones")
        let schema = directory.appendingPathComponent("safe-zones-v1.schema.json")
        #expect(FileManager.default.fileExists(atPath: schema.path))

        for filename in [
            "douyin.json",
            "instagram-reels.json",
            "tiktok.json",
            "xiaohongshu-portrait.json",
            "xiaohongshu-square.json",
            "youtube-shorts.json",
        ] {
            let data = try Data(contentsOf: directory.appendingPathComponent(filename))
            let profile = try JSONDecoder().decode(SafeZoneProfile.self, from: data)
            #expect(profile.validationErrors().isEmpty,
                    "\(filename): \(profile.validationErrors().joined(separator: ", "))")
        }
    }

    @Test("Safe-zone semantic validation rejects invalid points")
    func safeZoneValidationRejectsInvalidPoint() {
        let bad = SafeZoneProfile(
            schemaVersion: 1,
            platformID: "bad",
            displayName: "Bad",
            aspect: .vertical9x16,
            sourceName: "Test",
            sourceURL: nil,
            validatedAt: "2026-06-25",
            regions: [
                SafeZoneRegion(
                    id: "bad-region",
                    kind: "occlusion",
                    points: [
                        SafeZonePoint(x: 0, y: 0),
                        SafeZonePoint(x: 1.1, y: 0),
                        SafeZonePoint(x: 0, y: 1),
                    ])
            ])

        #expect(!bad.validationErrors().isEmpty)
    }

    @Test("Safe-zone profiles allow compatible custom canvas sizes")
    func safeZoneProfilesAllowCompatibleCustomCanvasSizes() throws {
        let verticalProfile = try #require(SafeZoneLibrary.profile(id: "tiktok"))

        #expect(SafeZoneLibrary.validProfile(
            id: verticalProfile.platformID,
            for: .custom,
            renderSize: CGSize(width: 720, height: 1280)) != nil)
        #expect(SafeZoneLibrary.validProfile(
            id: verticalProfile.platformID,
            for: .custom,
            renderSize: CGSize(width: 1000, height: 1001)) == nil)
    }

    @Test("Unsupported cover destination types are rejected")
    func unsupportedCoverDestinationTypeRejected() {
        let type = UTType(exportedAs: "com.localcutstudio.tests.unsupported-cover-\(UUID().uuidString)")

        #expect(!EditorModel.supportsCoverImageDestination(type))
    }

    @Test("Cover preview invalidation ignores annotations and tracks visible content")
    func coverPreviewInvalidationKeyScopesToVisibleContent() {
        let project = Project()
        let initial = CoverPreviewInvalidationKey.make(for: project)

        project.markers = [TimelineMarker(time: CMTime(seconds: 1, preferredTimescale: 600))]
        project.audioTracks[0].clips.append(Clip(
            mediaID: UUID(),
            sourceStart: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            timelineStart: .zero))

        #expect(CoverPreviewInvalidationKey.make(for: project) == initial)

        project.videoTracks[0].clips.append(Clip(
            mediaID: UUID(),
            sourceStart: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            timelineStart: .zero))

        #expect(CoverPreviewInvalidationKey.make(for: project) != initial)
    }

    @Test("Preview canvas geometry aspect-fits vertical canvas")
    func previewCanvasGeometryAspectFits() {
        let rect = PreviewCanvasGeometry.canvasRect(
            container: CGSize(width: 800, height: 400),
            renderSize: CGSize(width: 1080, height: 1920))

        #expect(abs(rect.height - 400) < 0.001)
        #expect(abs(rect.width - 225) < 0.001)
        #expect(abs(rect.minX - 287.5) < 0.001)
    }

    @Test("Platform presets carry safe-zone metadata")
    func platformPresetsHaveMetadata() {
        let platformPresets = BuiltInExportPresets.all.filter { $0.platformMetadata != nil }
        let ids = Set(platformPresets.compactMap { $0.platformMetadata?.platformID })

        #expect(ids.contains("youtube-shorts"))
        #expect(ids.contains("douyin"))
        #expect(ids.contains("xiaohongshu"))
        #expect(ids.contains("instagram-reels"))
        #expect(ids.contains("tiktok"))
        #expect(BuiltInExportPresets.youTubeShorts.projectAspect == .vertical9x16)
    }

    @Test("Legacy export preset JSON decodes without platform metadata")
    func legacyExportPresetDecodes() throws {
        let json = """
        {
          "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "name": "Legacy",
          "containerFormat": "\(AVFileType.mp4.rawValue)",
          "videoCodec": "\(AVVideoCodecType.h264.rawValue)",
          "aspect": "widescreen",
          "targetSize": { "width": 1920, "height": 1080 },
          "bitrate": "standard",
          "audioConfig": {
            "codec": 1633772320,
            "bitrate": 128000,
            "sampleRate": 48000,
            "channels": 2
          }
        }
        """

        let decoded = try JSONDecoder().decode(ExportPreset.self, from: Data(json.utf8))

        #expect(decoded.platformMetadata == nil)
        #expect(decoded.projectAspect == .widescreen16x9)
    }

    @Test("Unknown export aspect decodes to widescreen fallback")
    func unknownExportAspectDecodesToFallback() throws {
        let json = """
        {
          "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "name": "Future",
          "containerFormat": "\(AVFileType.mp4.rawValue)",
          "videoCodec": "\(AVVideoCodecType.h264.rawValue)",
          "aspect": "foldable37x64",
          "targetSize": { "width": 1920, "height": 1080 },
          "bitrate": "standard",
          "audioConfig": {
            "codec": 1633772320,
            "bitrate": 128000,
            "sampleRate": 48000,
            "channels": 2
          }
        }
        """

        let decoded = try JSONDecoder().decode(ExportPreset.self, from: Data(json.utf8))

        #expect(decoded.aspect == .widescreen)
        #expect(decoded.projectAspect == .widescreen16x9)
    }
}
