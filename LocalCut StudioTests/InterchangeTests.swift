import Testing
import Foundation
import CoreMedia
@testable import LocalCutCore
@testable import LocalCut_Studio

// MARK: - Time Model Tests

@Suite("Interchange time model")
struct InterchangeTimeTests {

    @Test("project.frameRate wins when finite > 0")
    func projectFrameRateWins() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        #expect(tb.rate == 24)
        #expect(tb.frameDurationTimescale == 1)
    }

    @Test("Fallback is 30 when frameRate is 0")
    func fallbackTo30() {
        let doc = makeTestDoc(frameRate: 0)
        let tb = interchangeTimebase(for: doc)
        #expect(tb.rate == 30)
    }

    @Test("Fallback is 30 when frameRate is negative")
    func fallbackNegative() {
        let doc = makeTestDoc(frameRate: -1)
        let tb = interchangeTimebase(for: doc)
        #expect(tb.rate == 30)
    }

    @Test("23.976 rational representation preserved")
    func rational23976() {
        let doc = makeTestDoc(frameRate: 23.976)
        let tb = interchangeTimebase(for: doc)
        #expect(tb.rate == 24000)
        #expect(tb.frameDurationTimescale == 1001)
    }

    @Test("29.97 rational representation preserved")
    func rational2997() {
        let doc = makeTestDoc(frameRate: 29.97)
        let tb = interchangeTimebase(for: doc)
        #expect(tb.rate == 30000)
        #expect(tb.frameDurationTimescale == 1001)
    }

    @Test("59.94 rational representation preserved")
    func rational5994() {
        let doc = makeTestDoc(frameRate: 59.94)
        let tb = interchangeTimebase(for: doc)
        #expect(tb.rate == 60000)
        #expect(tb.frameDurationTimescale == 1001)
    }

    @Test("Integer rate preserved")
    func integerRate() {
        let doc = makeTestDoc(frameRate: 25)
        let tb = interchangeTimebase(for: doc)
        #expect(tb.rate == 25)
        #expect(tb.frameDurationTimescale == 1)
    }

    @Test("Frame snapping at 24fps")
    func snapAt24fps() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        // 1 frame at 24fps = 1/24 second ≈ 0.04167s
        let time = CMTime(value: 3, timescale: 24) // 3 frames
        let snapped = tb.snapToFrames(time)
        #expect(snapped == time)
    }

    @Test("Frame snapping rounds to nearest frame")
    func snapRoundsCorrectly() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        // Halfway between frames 1 and 2.
        let halfway = CMTime(value: 3, timescale: 48) // 3/48 = 1/16 = 0.0625s
        // Frame 1 = 1/24 = 0.04167s, Frame 2 = 2/24 = 0.08333s
        // 0.0625 is closer to 0.08333 (frame 2) than 0.04167 (frame 1)
        let snapped = tb.snapToFrames(halfway)
        let expected = CMTime(value: 2, timescale: 24)
        #expect(snapped == expected)
    }

    @Test("Adjacent clips stay adjacent after snapping")
    func adjacentClipsStayAdjacent() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        let clip1 = ClipDoc(
            mediaID: UUID(),
            sourceStart: CMTimeCode(CMTime.zero),
            duration: CMTimeCode(CMTime(value: 24, timescale: 24)), // 1 second
            timelineStart: CMTimeCode(CMTime.zero),
            opacity: 1,
            effects: [],
            transition: nil)
        let clip2 = ClipDoc(
            mediaID: UUID(),
            sourceStart: CMTimeCode(CMTime.zero),
            duration: CMTimeCode(CMTime(value: 24, timescale: 24)),
            timelineStart: CMTimeCode(CMTime(value: 24, timescale: 24)), // starts where clip1 ends
            opacity: 1,
            effects: [],
            transition: nil)
        let snapped = snapTrackClips([clip1, clip2], timebase: tb)
        #expect(snapped.count == 2)
        #expect(snapped[0].timelineEnd == snapped[1].timelineStart)
    }

    @Test("Independent boundary snapping produces correct duration")
    func independentBoundarySnap() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        // Clip clearly between frame 0 and frame 3.
        // Start at 1/96s (0.25 frames — closer to frame 0), end at 11/96s (2.75 frames — closer to frame 3).
        let clip = ClipDoc(
            mediaID: UUID(),
            sourceStart: CMTimeCode(CMTime.zero),
            duration: CMTimeCode(CMTime(value: 10, timescale: 96)), // 10/96s
            timelineStart: CMTimeCode(CMTime(value: 1, timescale: 96)), // 1/96s
            opacity: 1,
            effects: [],
            transition: nil)
        let snapped = snapTrackClips([clip], timebase: tb)
        #expect(snapped.count == 1)
        // Timeline start snaps to frame 0, end snaps to frame 3, duration = 3 frames.
        #expect(snapped[0].timelineStart == CMTime.zero)
        let expectedDuration = CMTime(value: 3, timescale: 24)
        #expect(snapped[0].timelineDuration == expectedDuration)
    }

    @Test("Micro-gap below threshold collapses")
    func microGapCollapse() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        // Gap of 0.5ms (well below threshold of ~20.8ms at 24fps).
        let items: [(start: CMTime, end: CMTime)] = [
            (CMTime.zero, CMTime(value: 1, timescale: 1)),
            (CMTime(value: 10005, timescale: 10000), CMTime(value: 2, timescale: 1)),
        ]
        let collapsed = collapseGaps(items: items, threshold: tb.microGapThreshold)
        #expect(collapsed[1].start == collapsed[0].end)
    }

    @Test("Real gap above threshold remains")
    func realGapRemains() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        // Gap of 0.5 seconds — well above threshold.
        let items: [(start: CMTime, end: CMTime)] = [
            (CMTime.zero, CMTime(value: 1, timescale: 1)),
            (CMTime(value: 3, timescale: 2), CMTime(value: 2, timescale: 1)),
        ]
        let collapsed = collapseGaps(items: items, threshold: tb.microGapThreshold)
        #expect(collapsed[1].start == CMTime(value: 3, timescale: 2))
    }

    @Test("Zero-frame clip emits warning")
    func zeroFrameClipWarning() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        // Clip with zero duration after snapping.
        let clip = ClipDoc(
            mediaID: UUID(),
            sourceStart: CMTimeCode(CMTime.zero),
            duration: CMTimeCode(CMTime(value: 1, timescale: 1000)), // 1ms — less than 1 frame
            timelineStart: CMTimeCode(CMTime.zero),
            opacity: 1,
            effects: [],
            transition: nil)
        let snapped = snapTrackClips([clip], timebase: tb)
        #expect(snapped.isEmpty) // Dropped.
    }

    @Test("Timecode formatting starts at 00:00:00:00")
    func timecodeFormatting() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        let tc = formatTimecode(CMTime.zero, timebase: tb)
        #expect(tc == "00:00:00:00")
    }

    @Test("Timecode formatting at 1 second")
    func timecodeAt1Second() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        let tc = formatTimecode(CMTime(value: 1, timescale: 1), timebase: tb)
        #expect(tc == "00:00:01:00")
    }

    @Test("Timecode formatting at 1 frame")
    func timecodeAt1Frame() {
        let doc = makeTestDoc(frameRate: 24)
        let tb = interchangeTimebase(for: doc)
        let tc = formatTimecode(CMTime(value: 1, timescale: 24), timebase: tb)
        #expect(tc == "00:00:00:01")
    }
}

// MARK: - OTIO Node Tests

@Suite("OTIO schema nodes")
struct OtioNodeTests {

    @Test("Allowed schema names are in allowlist")
    func allowedSchemas() {
        for schema in OtioSchema.allCases {
            #expect(OtioSchema.allowlist.contains(schema.rawValue))
        }
    }

    @Test("RationalTime encodes correctly")
    func rationalTimeEncodes() {
        let rt = OtioRationalTime(value: 24, rate: 24)
        let dict = rt.toDictionary()
        #expect(dict["OTIO_SCHEMA"] as? String == "RationalTime.1")
        #expect(dict["value"] as? Int == 24)
        #expect(dict["rate"] as? Int == 24)
    }

    @Test("Clip uses Clip.2 schema")
    func clipUsesSchema2() {
        let clip = OtioClip(
            name: "Test",
            sourceRange: OtioTimeRange(
                startTime: OtioRationalTime(value: 0, rate: 24),
                duration: OtioRationalTime(value: 24, rate: 24)),
            mediaReferences: ["DEFAULT_MEDIA": .missing(OtioMissingReference(name: nil))],
            activeKey: "DEFAULT_MEDIA",
            metadata: nil)
        let dict = clip.toDictionary()
        #expect(dict["OTIO_SCHEMA"] as? String == "Clip.2")
        #expect(dict["media_references"] != nil)
        #expect(dict["active_media_reference_key"] as? String == "DEFAULT_MEDIA")
    }

    @Test("LocalCut metadata nested under metadata.localcut")
    func localcutMetadataNesting() {
        let clip = OtioClip(
            name: "Test",
            sourceRange: OtioTimeRange(
                startTime: OtioRationalTime(value: 0, rate: 24),
                duration: OtioRationalTime(value: 24, rate: 24)),
            mediaReferences: ["DEFAULT_MEDIA": .missing(OtioMissingReference(name: nil))],
            activeKey: "DEFAULT_MEDIA",
            metadata: ["localcut": ["opacity": 0.5]])
        let dict = clip.toDictionary()
        let meta = dict["metadata"] as? [String: Any]
        let localcut = meta?["localcut"] as? [String: Any]
        #expect(localcut?["opacity"] as? Double == 0.5)
    }
}

// MARK: - OTIO Validator Tests

@Suite("OTIO structural validator")
struct OtioValidatorTests {

    @Test("Valid golden-like document passes")
    func validDocumentPasses() {
        let json = """
        {
            "OTIO_SCHEMA": "Timeline.1",
            "name": "Test",
            "global_start_time": {"OTIO_SCHEMA": "RationalTime.1", "value": 0, "rate": 24},
            "tracks": {
                "OTIO_SCHEMA": "Stack.1",
                "name": "tracks",
                "children": []
            }
        }
        """
        let errors = validateOtioDocument(json)
        #expect(errors.isEmpty)
    }

    @Test("Unknown schema fails")
    func unknownSchemaFails() {
        let json = """
        {"OTIO_SCHEMA": "Foo.1"}
        """
        let errors = validateOtioDocument(json)
        #expect(errors.contains { $0 == .unsupportedSchema("Foo.1") })
    }

    @Test("Missing required field fails")
    func missingFieldFails() {
        let json = """
        {"OTIO_SCHEMA": "Timeline.1"}
        """
        let errors = validateOtioDocument(json)
        #expect(errors.contains { if case .missingRequiredField("name", _) = $0 { return true }; return false })
    }

    @Test("Negative duration fails")
    func negativeDurationFails() {
        let json = """
        {
            "OTIO_SCHEMA": "TimeRange.1",
            "start_time": {"OTIO_SCHEMA": "RationalTime.1", "value": 0, "rate": 24},
            "duration": {"OTIO_SCHEMA": "RationalTime.1", "value": -1, "rate": 24}
        }
        """
        let errors = validateOtioDocument(json)
        #expect(errors.contains { if case .negativeDuration = $0 { return true }; return false })
    }

    @Test("Clip without active media ref fails")
    func clipWithoutActiveRefFails() {
        let json = """
        {
            "OTIO_SCHEMA": "Clip.2",
            "name": "Test",
            "source_range": {
                "OTIO_SCHEMA": "TimeRange.1",
                "start_time": {"OTIO_SCHEMA": "RationalTime.1", "value": 0, "rate": 24},
                "duration": {"OTIO_SCHEMA": "RationalTime.1", "value": 24, "rate": 24}
            },
            "media_references": {},
            "active_media_reference_key": "MISSING"
        }
        """
        let errors = validateOtioDocument(json)
        #expect(errors.contains { if case .invalidClipMediaReference = $0 { return true }; return false })
    }

    @Test("LocalCut metadata does not fail validation")
    func localcutMetadataValid() {
        let json = """
        {
            "OTIO_SCHEMA": "Timeline.1",
            "name": "Test",
            "global_start_time": {"OTIO_SCHEMA": "RationalTime.1", "value": 0, "rate": 24},
            "tracks": {
                "OTIO_SCHEMA": "Stack.1",
                "name": "tracks",
                "children": []
            },
            "metadata": {
                "localcut": {"captionTracks": []}
            }
        }
        """
        let errors = validateOtioDocument(json)
        #expect(errors.isEmpty)
    }
}

// MARK: - OTIO Serializer Tests

@Suite("OTIO serializer")
struct OtioSerializerTests {

    @Test("Basic project serializes to Timeline/Stack/Track")
    func basicSerialization() {
        let doc = makeTestDoc(frameRate: 24)
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(!json.isEmpty)
        #expect(warnings.isEmpty)
        // Validate structure.
        let errors = validateOtioDocument(json)
        #expect(errors.isEmpty, "Validation errors: \(errors)")
    }

    @Test("Deterministic byte equality across repeated calls")
    func deterministicOutput() {
        let doc = makeTestDoc(frameRate: 24)
        let (json1, _) = serializeTimelineToOtio(doc)
        let (json2, _) = serializeTimelineToOtio(doc)
        #expect(json1 == json2)
    }

    @Test("Video track maps to kind Video")
    func videoTrackKind() {
        let doc = makeTestDoc(frameRate: 24, videoClips: 1)
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("\"kind\" : \"Video\""))
    }

    @Test("Audio track maps to kind Audio")
    func audioTrackKind() {
        let doc = makeTestDoc(frameRate: 24, audioClips: 1)
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("\"kind\" : \"Audio\""))
    }

    @Test("Missing media emits MissingReference.1")
    func missingMediaReference() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
        ])
        // No matching media entry — will be missing.
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("MissingReference.1"))
    }

    @Test("Markers emit on Stack")
    func markersOnStack() {
        var doc = makeTestDoc(frameRate: 24)
        doc.markers = [TimelineMarker(time: CMTime(value: 12, timescale: 24), name: "Chapter 1")]
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("Marker.2"))
        #expect(json.contains("Chapter 1"))
    }

    @Test("Cross dissolve maps to SMPTE_Dissolve")
    func crossDissolveMapping() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
            testClipDoc(mediaID: mediaID, timelineStart: CMTime(value: 24, timescale: 24),
                        durationFrames: 24, rate: 24,
                        transition: TransitionDoc(type: "crossDissolve",
                                                  duration: CMTimeCode(CMTime(value: 12, timescale: 24)))),
        ])
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("SMPTE_Dissolve"))
    }

    @Test("Wipe maps to Custom_Transition")
    func wipeMapping() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
            testClipDoc(mediaID: mediaID, timelineStart: CMTime(value: 24, timescale: 24),
                        durationFrames: 24, rate: 24,
                        transition: TransitionDoc(type: "wipe",
                                                  duration: CMTimeCode(CMTime(value: 12, timescale: 24)))),
        ])
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("Custom_Transition"))
    }

    @Test("Effects under metadata.localcut")
    func effectsInLocalcutMetadata() {
        let mediaID = UUID()
        var clip = testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24)
        clip.effects = [.colourGrade(ColourGrade(exposure: 0.5, contrast: 1.1, saturation: 1.0,
                                                  temperatureOffset: 0, tintOffset: 0))]
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [clip])
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("\"localcut\""))
        #expect(json.contains("colourGrade"))
    }

    @Test("LUT metadata omits unstable bookmark hashes")
    func lutMetadataOmitsBookmarkHash() {
        let mediaID = UUID()
        var clip = testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24)
        clip.effects = [.lut(bookmark: Data([0x01, 0x02, 0x03]))]
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [clip])
        let (json, _) = serializeTimelineToOtio(doc)

        #expect(json.contains("\"type\" : \"lut\""))
        #expect(!json.contains("bookmarkHash"))
    }

    @Test("External references carry resolved fingerprints")
    func externalReferenceFingerprintMetadata() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
        ])
        let (json, _) = serializeTimelineToOtio(
            doc,
            options: OtioSerializationOptions(
                resolveTargetUrl: { _ in "assets/test.mov" },
                resolveFingerprint: { _ in "abc123" }))

        #expect(json.contains("\"metadata\""))
        #expect(json.contains("\"fingerprint\" : \"abc123\""))
        #expect(validateOtioDocument(json).isEmpty)
    }

    @Test("Caption tracks under timeline localcut metadata")
    func captionTracksInMetadata() {
        var doc = makeTestDoc(frameRate: 24)
        doc.captionTracks = [CaptionTrackDoc(
            id: UUID(), name: "Captions", isMuted: false,
            defaultStyle: CaptionStyle(), lines: [])]
        let (json, _) = serializeTimelineToOtio(doc)
        #expect(json.contains("captionTracks"))
    }
}

// MARK: - EDL Serializer Tests

@Suite("EDL serializer")
struct EdlSerializerTests {

    @Test("Single-track EDL output")
    func singleTrackEdl() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
        ])
        let (edl, _) = serializeTimelineToEdl(doc)
        #expect(!edl.isEmpty)
        #expect(edl.contains("TITLE:"))
    }

    @Test("Record TC starts at 01:00:00:00")
    func recordTCStarts() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
        ])
        let (edl, _) = serializeTimelineToEdl(doc)
        #expect(edl.contains("01:00:00:00"))
    }

    @Test("Reel name normalization")
    func reelNameNormalization() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, media: [
            testMediaRef(id: mediaID, displayName: "My Long Media File Name"),
        ], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
        ])
        let (edl, _) = serializeTimelineToEdl(doc)
        // Reel name should be uppercase, max 8 chars.
        #expect(edl.contains("MYLONGME"))
    }

    @Test("Title uses reel AX")
    func titleUsesAX() {
        // A clip with no matching media reference → AX reel.
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
        ])
        let (edl, _) = serializeTimelineToEdl(doc)
        #expect(edl.contains("AX"))
    }

    @Test("Fractional rate comment emitted")
    func fractionalRateComment() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 29.97, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 30, rate: 30),
        ])
        let (edl, _) = serializeTimelineToEdl(doc)
        #expect(edl.contains("LOCALCUT: RATE"))
    }

    @Test("Byte-identical EDL across runs")
    func deterministicEdl() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 24, rate: 24),
        ])
        let (edl1, _) = serializeTimelineToEdl(doc)
        let (edl2, _) = serializeTimelineToEdl(doc)
        #expect(edl1 == edl2)
    }
}

// MARK: - EDL Validator Tests

@Suite("EDL grammar validator")
struct EdlValidatorTests {

    @Test("Valid EDL passes")
    func validEdlPasses() {
        let edl = """
        TITLE: Test

        001  MYREEL   V     C     00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00
        * FROM CLIP NAME: Test Clip

        """
        let errors = validateEdl(edl)
        #expect(errors.isEmpty, "Errors: \(errors)")
    }

    @Test("Long reel name fails")
    func longReelNameFails() {
        let edl = "001  TOOLONGNAME  V     C     00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00"
        let errors = validateEdl(edl)
        #expect(errors.contains { if case .reelNameTooLong = $0 { return true }; return false })
    }

    @Test("Lowercase reel fails")
    func lowercaseReelFails() {
        let edl = "001  myreel   V     C     00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00"
        let errors = validateEdl(edl)
        #expect(errors.contains { if case .reelNameNotUppercaseAlphanumeric = $0 { return true }; return false })
    }

    @Test("Missing timecode fails")
    func missingTimecodeFails() {
        let edl = "001  MYREEL   V     C     00:00:00:00"
        let errors = validateEdl(edl)
        #expect(errors.contains { if case .malformedLine = $0 { return true }; return false })
    }

    @Test("Invalid event number fails")
    func invalidEventNumberFails() {
        let edl = "ABC  MYREEL   V     C     00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00"
        let errors = validateEdl(edl)
        #expect(errors.contains { if case .invalidEventNumber = $0 { return true }; return false })
    }

    @Test("LocalCut comment line passes")
    func localcutCommentPasses() {
        let edl = """
        * LOCALCUT: RATE 29.97 ROUNDED TO 30 NDF
        001  MYREEL   V     C     00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00
        """
        let errors = validateEdl(edl)
        #expect(errors.isEmpty, "Errors: \(errors)")
    }
}

// MARK: - Warning Tests

@Suite("Interchange warnings")
struct InterchangeWarningTests {

    @Test("Zero-frame clip warning")
    func zeroFrameWarning() {
        let w = zeroFrameClipWarning(mediaID: UUID(), trackName: "V1")
        #expect(w.kind == .zeroFrameClip)
        #expect(!w.message.isEmpty)
    }

    @Test("Orphan transition warning")
    func orphanTransitionWarningTest() {
        let w = LocalCut_Studio.orphanTransitionWarning(clipID: UUID(), trackName: "V1")
        #expect(w.kind == .orphanTransition)
    }

    @Test("Missing source warning")
    func missingSourceWarningTest() {
        let w = LocalCut_Studio.missingSourceWarning(mediaID: UUID(), trackName: "V1", clipName: nil)
        #expect(w.kind == .missingSource)
    }

    @Test("Non-uniform speed warning")
    func nonUniformSpeedWarningTest() {
        let w = LocalCut_Studio.nonUniformSpeedWarning(clipID: UUID(), trackName: "V1")
        #expect(w.kind == .nonUniformSpeedCurve)
    }

    @Test("Warnings are stable/deterministic")
    func warningsDeterministic() {
        let id = UUID()
        let w1 = zeroFrameClipWarning(mediaID: id, trackName: "V1")
        let w2 = zeroFrameClipWarning(mediaID: id, trackName: "V1")
        #expect(w1 == w2)
    }
}

// MARK: - Golden Fixture Tests

@Suite("Golden fixtures")
struct GoldenFixtureTests {

    @Test("Basic OTIO golden structural check")
    func basicOtioGolden() {
        let mediaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24),
            testClipDoc(mediaID: mediaID, timelineStart: CMTime(value: 48, timescale: 24),
                        durationFrames: 24, rate: 24),
        ])
        let (json, warnings) = serializeTimelineToOtio(doc)
        #expect(warnings.isEmpty)
        // Validate structure.
        let errors = validateOtioDocument(json)
        #expect(errors.isEmpty, "Validation errors: \(errors)")
        // Validate key content.
        #expect(json.contains("Timeline.1"))
        #expect(json.contains("Stack.1"))
        #expect(json.contains("Track.1"))
        #expect(json.contains("Clip.2"))
        #expect(json.contains("ExternalReference.1"))
        #expect(json.contains("00000000-0000-0000-0000-000000000001"))
        #expect(json.contains("TestMedia.mov"))
        #expect(json.contains("Video"))
        // Deterministic: repeated calls produce identical output.
        let (json2, _) = serializeTimelineToOtio(doc)
        #expect(json == json2)
    }

    @Test("Basic EDL golden structural check")
    func basicEdlGolden() {
        let mediaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24),
            testClipDoc(mediaID: mediaID, timelineStart: CMTime(value: 48, timescale: 24),
                        durationFrames: 24, rate: 24),
        ])
        let (edl, warnings) = serializeTimelineToEdl(doc)
        #expect(warnings.isEmpty)
        // Validate structure.
        let errors = validateEdl(edl)
        #expect(errors.isEmpty, "EDL validation errors: \(errors)")
        // Validate key content.
        #expect(edl.contains("TITLE: Test Project"))
        #expect(edl.contains("01:00:00:00"))
        #expect(edl.contains("TESTMOV"))
        #expect(edl.contains("V     C"))
        // Deterministic.
        let (edl2, _) = serializeTimelineToEdl(doc)
        #expect(edl == edl2)
    }

    @Test("Structural validator passes generated OTIO")
    func validatorPassesGoldens() {
        let mediaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24),
        ])
        let (json, _) = serializeTimelineToOtio(doc)
        let errors = validateOtioDocument(json)
        #expect(errors.isEmpty, "OTIO validation errors: \(errors)")
    }

    @Test("EDL validator passes generated EDL")
    func edlValidatorPassesGoldens() {
        let mediaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let doc = makeTestDoc(frameRate: 24, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 48, rate: 24),
        ])
        let (edl, _) = serializeTimelineToEdl(doc)
        let errors = validateEdl(edl)
        #expect(errors.isEmpty, "EDL validation errors: \(errors)")
    }
}

// MARK: - Test Helpers

private func makeTestDoc(frameRate: Double,
                         media: [MediaRef] = [],
                         videoClips: Int = 0,
                         audioClips: Int = 0,
                         clips: [ClipDoc]? = nil) -> ProjectDocument {
    let videoTrackClips = clips ?? (0..<videoClips).map { i in
        testClipDoc(mediaID: media.first?.id ?? UUID(),
                    timelineStart: CMTime(value: Int64(i * 24), timescale: 24),
                    durationFrames: 24, rate: 24)
    }
    let audioTrackClips = (0..<audioClips).map { i in
        testClipDoc(mediaID: media.first?.id ?? UUID(),
                    timelineStart: CMTime(value: Int64(i * 24), timescale: 24),
                    durationFrames: 24, rate: 24)
    }
    return ProjectDocument(
        name: "Test Project",
        renderWidth: 1920,
        renderHeight: 1080,
        frameRate: frameRate,
        media: media,
        videoTracks: videoTrackClips.isEmpty ? [] : [
            TrackDoc(name: "V1", kind: "video", isMuted: false, clips: videoTrackClips),
        ],
        audioTracks: audioTrackClips.isEmpty ? [] : [
            TrackDoc(name: "A1", kind: "audio", isMuted: false, clips: audioTrackClips),
        ])
}

private func testMediaRef(id: UUID = UUID(),
                          displayName: String = "TestMedia.mov",
                          bookmark: Data = Data([0x01]),
                          bundleRelativePath: String? = nil) -> MediaRef {
    MediaRef(
        id: id,
        displayName: displayName,
        bookmark: bookmark,
        duration: CMTimeCode(CMTime(value: 240, timescale: 24)),
        naturalWidth: 1920,
        naturalHeight: 1080,
        preferredTransform: TransformCode(.identity),
        hasVideo: true,
        hasAudio: true,
        bundleRelativePath: bundleRelativePath)
}

private func testClipDoc(mediaID: UUID = UUID(),
                         timelineStart: CMTime,
                         durationFrames: Int,
                         rate: Int,
                         transition: TransitionDoc? = nil) -> ClipDoc {
    ClipDoc(
        mediaID: mediaID,
        sourceStart: CMTimeCode(CMTime.zero),
        duration: CMTimeCode(CMTime(value: Int64(durationFrames), timescale: Int32(rate))),
        timelineStart: CMTimeCode(timelineStart),
        opacity: 1,
        effects: [],
        transition: transition)
}
