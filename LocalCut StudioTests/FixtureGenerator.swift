import Testing
import Foundation
import CoreMedia
@testable import LocalCutCore
@testable import LocalCut_Studio

/// Generates fixture content and writes to /tmp for manual collection.
/// Run: xcodebuild test -only-testing "LocalCut StudioTests/FixtureGenerator"
/// Then copy files from /tmp/localcut-fixtures/ to Tests/Fixtures/Interchange/.
@Suite("Fixture generator")
struct FixtureGenerator {

    private func writeFixture(_ name: String, content: String) throws {
        let dir = "/tmp/localcut-fixtures"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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
        let (json, _) = serializeTimelineToOtio(doc, options: opts)
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
        let (edl, _) = serializeTimelineToEdl(doc)
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
        let (json, _) = serializeTimelineToOtio(doc)
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
        let (edl, _) = serializeTimelineToEdl(doc)
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
        let (json, _) = serializeTimelineToOtio(doc)
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
        let (json, _) = serializeTimelineToOtio(doc)
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
        let (json, _) = serializeTimelineToOtio(doc)
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
        let (json, _) = serializeTimelineToOtio(doc)
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
        let (json, _) = serializeTimelineToOtio(doc)
        try writeFixture("localcut_metadata.otio", content: json)
    }
}
