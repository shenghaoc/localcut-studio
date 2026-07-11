import Testing
import Foundation
import CoreMedia
@testable import LocalCutCore
@testable import LocalCut_Studio

/// Generates fixture content and writes to disk for manual collection.
///
/// **Normal test mode:** tests pass without writing anything — the golden
/// fixture tests in `GoldenFixtureTests` validate the serializer output
/// against the committed fixtures under `Tests/Fixtures/Interchange/`.
/// The serializer code paths (OTIO and EDL) are still exercised in this
/// mode; only the disk write is skipped.
///
/// **Explicit regeneration mode:** pass the `LOCALCUT_REGENERATE_FIXTURES`
/// Swift compilation condition to write generated fixtures to a unique
/// temporary directory per run. A runtime `LOCALCUT_REGENERATE_FIXTURES=1`
/// environment variable is also accepted when the test host propagates it.
///
///     xcodebuild test -only-testing "LocalCut StudioTests/FixtureGenerator" \
///       OTHER_SWIFT_FLAGS='$(inherited) -D LOCALCUT_REGENERATE_FIXTURES'
///
/// The output directory is the test host temporary directory with a
/// `localcut-fixtures-<UUID>` suffix. For the sandboxed app host this is under
/// `~/Library/Containers/com.shenghaoc.LocalCutStudio/Data/tmp/`.
@Suite("Fixture generator")
struct FixtureGenerator {

    /// Whether this run should actually write fixture files to disk.
    /// The compile-time flag is the reliable xcodebuild CLI path; the runtime
    /// env var keeps compatibility with runners that pass env through.
    private static var isRegenerationEnabled: Bool {
#if LOCALCUT_REGENERATE_FIXTURES
        true
#else
        ProcessInfo.processInfo.environment["LOCALCUT_REGENERATE_FIXTURES"] == "1"
#endif
    }

    /// Shared output directory for this regeneration run, created once lazily.
    /// Uses a UUID-based subdirectory to avoid collisions between parallel runs.
    private static let outputDirectory: String? = {
        guard isRegenerationEnabled else { return nil }
        let base = FileManager.default.temporaryDirectory.path
        let dir = (base as NSString).appendingPathComponent("localcut-fixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        print("FixtureGenerator: writing to \(dir)")
        return dir
    }()

    private func writeFixture(_ name: String, content: String) throws {
        guard let dir = Self.outputDirectory else { return }
        let path = "\(dir)/\(name)"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(path)")
    }

    // MARK: - Basic (24fps, 1 video track, 2 clips)

    @Test("Generate basic.otio")
    func generateBasicOtio() throws {
        let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        let doc = ProjectDocument(
            name: "Basic Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 24,
            media: [testMediaRef(id: mediaID, displayName: "TestMedia.mov")],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24),
                testClipDoc(mediaID: mediaID, timelineStart: CMTime(value: 48, timescale: 24),
                            durationFrames: 24, rate: 24),
            ])],
            audioTracks: [])
        let opts = OtioSerializationOptions(
            bundleMode: true,
            resolveTargetUrl: { _ in "assets/test.mov" },
            resolveFingerprint: { _ in "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" })
        let (json, warnings) = serializeTimelineToOtio(doc, options: opts)
        #expect(!json.isEmpty)
        #expect(warnings.isEmpty)
        #expect(validateOtioDocument(json).isEmpty)
        try writeFixture("basic.otio", content: json)
    }

    @Test("Generate basic.edl")
    func generateBasicEdl() throws {
        let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        let doc = ProjectDocument(
            name: "Basic Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 24,
            media: [testMediaRef(id: mediaID, displayName: "TestMedia.mov")],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24),
                testClipDoc(mediaID: mediaID, timelineStart: CMTime(value: 48, timescale: 24),
                            durationFrames: 24, rate: 24),
            ])],
            audioTracks: [])
        let (edl, warnings) = serializeTimelineToEdl(doc)
        #expect(!edl.isEmpty)
        #expect(warnings.isEmpty)
        #expect(validateEdl(edl).isEmpty)
        try writeFixture("basic.edl", content: edl)
    }

    // MARK: - Fractional frame rate (29.97fps)

    @Test("Generate fractional.otio")
    func generateFractionalOtio() throws {
        let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
        let doc = ProjectDocument(
            name: "Fractional Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 29.97,
            media: [testMediaRef(id: mediaID, displayName: "Clip2997.mov")],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 60, rate: 30),
            ])],
            audioTracks: [])
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(!json.isEmpty)
        #expect(warnings.isEmpty)
        #expect(validateOtioDocument(json).isEmpty)
        try writeFixture("fractional.otio", content: json)
    }

    @Test("Generate fractional.edl")
    func generateFractionalEdl() throws {
        let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
        let doc = ProjectDocument(
            name: "Fractional Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 29.97,
            media: [testMediaRef(id: mediaID, displayName: "Clip2997.mov")],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 60, rate: 30),
            ])],
            audioTracks: [])
        let (edl, warnings) = serializeTimelineToEdl(doc)
        #expect(!edl.isEmpty)
        #expect(warnings.isEmpty)
        #expect(validateEdl(edl).isEmpty)
        try writeFixture("fractional.edl", content: edl)
    }

    // MARK: - Transitions

    @Test("Generate transitions.otio")
    func generateTransitionsOtio() throws {
        let mediaA = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
        let mediaB = UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!
        let doc = ProjectDocument(
            name: "Transitions Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 24,
            media: [
                testMediaRef(id: mediaA, displayName: "ClipA.mov"),
                testMediaRef(id: mediaB, displayName: "ClipB.mov"),
            ],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaA, timelineStart: .zero, durationFrames: 48, rate: 24),
                testClipDoc(mediaID: mediaB,
                            timelineStart: CMTime(value: 48, timescale: 24),
                            durationFrames: 48, rate: 24,
                            transition: TransitionDoc(type: "crossDissolve",
                                                      duration: CMTimeCode(CMTime(value: 12, timescale: 24)))),
            ])],
            audioTracks: [])
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(!json.isEmpty)
        #expect(warnings.isEmpty)
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("SMPTE_Dissolve"))
        try writeFixture("transitions.otio", content: json)
    }

    // MARK: - Missing media

    @Test("Generate missing_media.otio")
    func generateMissingMediaOtio() throws {
        let missingID = UUID(uuidString: "A0000000-0000-0000-0000-00000000DEAD")!
        let doc = ProjectDocument(
            name: "Missing Media Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 24,
            media: [],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: missingID, timelineStart: .zero, durationFrames: 24, rate: 24),
            ])],
            audioTracks: [])
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(!json.isEmpty)
        #expect(!warnings.isEmpty) // Should have missing-source warnings
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("MissingReference.1"))
        try writeFixture("missing_media.otio", content: json)
    }

    // MARK: - Markers

    @Test("Generate markers.otio")
    func generateMarkersOtio() throws {
        let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!
        let doc = ProjectDocument(
            name: "Markers Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 24,
            media: [testMediaRef(id: mediaID, displayName: "MarkerClip.mov")],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 96, rate: 24),
            ])],
            audioTracks: [],
            markers: [
                TimelineMarker(id: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
                               time: CMTime(value: 0, timescale: 24), name: "Start"),
                TimelineMarker(id: UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!,
                               time: CMTime(value: 48, timescale: 24), name: "Middle"),
            ])
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(!json.isEmpty)
        #expect(warnings.isEmpty)
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("Marker.2"))
        #expect(json.contains("Start"))
        #expect(json.contains("Middle"))
        try writeFixture("markers.otio", content: json)
    }

    // MARK: - Speed ramp metadata

    @Test("Generate speed_ramp.otio")
    func generateSpeedRampOtio() throws {
        let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!
        let speedCurve = Keyframed<Float>(
            keyframes: [
                Keyframe(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!,
                         time: CMTime.zero, value: 1.0),
                Keyframe(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!,
                         time: CMTime(value: 24, timescale: 24), value: 2.0),
                Keyframe(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000003")!,
                         time: CMTime(value: 48, timescale: 24), value: 1.0),
            ],
            defaultValue: 1.0)
        let doc = ProjectDocument(
            name: "Speed Ramp Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 24,
            media: [testMediaRef(id: mediaID, displayName: "SpeedClip.mov")],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24,
                            speedCurve: speedCurve),
            ])],
            audioTracks: [])
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(!json.isEmpty)
        #expect(!warnings.isEmpty) // Non-uniform speed curve warning
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("speedCurve"))
        try writeFixture("speed_ramp.otio", content: json)
    }

    // MARK: - LocalCut metadata (effects, captions)

    @Test("Generate localcut_metadata.otio")
    func generateLocalcutMetadataOtio() throws {
        let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!
        let doc = ProjectDocument(
            name: "Metadata Fixture",
            renderWidth: 1920, renderHeight: 1080, frameRate: 24,
            media: [testMediaRef(id: mediaID, displayName: "EffectClip.mov")],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24,
                            effects: [
                                .colourGrade(ColourGrade(exposure: 0.5, contrast: 1.2, saturation: 0.9,
                                                         temperatureOffset: 100, tintOffset: -20)),
                                .grain(GrainEffect(amount: Keyframed<Float>(defaultValue: 0.3),
                                                   size: 2.0, monochrome: true, seed: 42)),
                            ],
                            opacity: 0.8),
            ])],
            audioTracks: [],
            captionTracks: [CaptionTrackDoc(
                id: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!,
                name: "Subtitles", isMuted: false,
                defaultStyle: CaptionStyle(),
                lines: [CaptionLine(
                    id: UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!,
                    range: CMTimeRange(start: CMTime.zero,
                                       duration: CMTime(value: 48, timescale: 24)),
                    text: "Hello world")])])
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(!json.isEmpty)
        #expect(warnings.isEmpty)
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("colourGrade"))
        #expect(json.contains("captionTracks"))
        #expect(json.contains("Hello world"))
        try writeFixture("localcut_metadata.otio", content: json)
    }

    // MARK: - Isolation regression test

    @Test("Normal mode writeFixture is a no-op")
    func normalModeWriteFixtureIsNoOp() throws {
        guard !Self.isRegenerationEnabled else { return }

        let tmpBase = FileManager.default.temporaryDirectory.path
        let fm = FileManager.default
        let before = Set(try fm.contentsOfDirectory(atPath: tmpBase))
        let sentinelName = "normal-mode-\(UUID().uuidString).otio"
        let legacyDir = (tmpBase as NSString).appendingPathComponent("localcut-fixtures")
        let legacyPath = (legacyDir as NSString).appendingPathComponent(sentinelName)

        #expect(Self.outputDirectory == nil, "outputDirectory should be nil in normal mode")
        try writeFixture(sentinelName, content: "sentinel")
        #expect(Self.outputDirectory == nil, "writeFixture should not initialize an output directory")
        #expect(
            !fm.fileExists(atPath: legacyPath),
            "normal mode must not write to the legacy shared path")

        let after = Set(try fm.contentsOfDirectory(atPath: tmpBase))
        let createdFixtureDirs = after
            .subtracting(before)
            .filter { $0.hasPrefix("localcut-fixtures") }
        #expect(
            createdFixtureDirs.isEmpty,
            "normal mode must not create fixture output directories")
    }

    @Test("Regeneration mode writeFixture writes a sentinel file")
    func regenerationModeWriteFixtureWritesSentinelFile() throws {
        guard Self.isRegenerationEnabled else { return }

        let dir = try #require(Self.outputDirectory)
        #expect(
            (dir as NSString).lastPathComponent.hasPrefix("localcut-fixtures-"),
            "regeneration output should use a UUID-scoped fixture directory")

        let sentinelName = "regeneration-mode-\(UUID().uuidString).otio"
        let sentinelPath = (dir as NSString).appendingPathComponent(sentinelName)
        try writeFixture(sentinelName, content: "sentinel")
        #expect(
            FileManager.default.fileExists(atPath: sentinelPath),
            "regeneration mode should write fixture content to the output directory")
    }
}
