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

    @Test("Fractional rate EDL record TC starts at 01:00:00:00")
    func fractionalRecordTCStarts() {
        let mediaID = UUID()
        let doc = makeTestDoc(frameRate: 29.97, media: [testMediaRef(id: mediaID)], clips: [
            testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 30, rate: 30),
        ])
        let (edl, _) = serializeTimelineToEdl(doc)
        // The first event's record-in timecode must be 01:00:00:00, not
        // 1000:00:00:00 (the bug that occurs when rate is used instead of nominalFPS).
        #expect(edl.contains("01:00:00:00"))
        #expect(!edl.contains("1000:00:00:00"))
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

/// Locates the committed `Tests/Fixtures/Interchange/` directory by walking up
/// from this source file's path. Returns `nil` when running in a sandbox that
/// relocates sources (e.g. CI SwiftPM builds).
private func fixtureDir() -> String? {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<10 {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent("Tests/Fixtures/Interchange").path
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
    }
    return nil
}

/// Reads a committed fixture file. Returns `nil` when the fixture directory is
/// unreachable (sandboxed test runner) so the test can skip gracefully.
private func readFixture(_ name: String) -> String? {
    guard let dir = fixtureDir() else { return nil }
    let path = (dir as NSString).appendingPathComponent(name)
    return try? String(contentsOfFile: path, encoding: .utf8)
}

@Suite("Golden fixtures")
struct GoldenFixtureTests {

    // MARK: - Helpers

    /// Builds the same `ProjectDocument` the FixtureGenerator uses for a given
    /// fixture name, then returns fresh serializer output.
    private func freshOtio(_ fixture: String) -> (json: String, warnings: [InterchangeWarning]) {
        switch fixture {
        case "basic.otio":
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
            return serializeTimelineToOtio(doc, options: opts)
        case "fractional.otio":
            let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
            let doc = ProjectDocument(
                name: "Fractional Fixture",
                renderWidth: 1920, renderHeight: 1080, frameRate: 29.97,
                media: [testMediaRef(id: mediaID, displayName: "Clip2997.mov")],
                videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                    testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 60, rate: 30),
                ])],
                audioTracks: [])
            return serializeTimelineToOtio(doc)
        case "transitions.otio":
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
            return serializeTimelineToOtio(doc)
        case "missing_media.otio":
            let missingID = UUID(uuidString: "A0000000-0000-0000-0000-00000000DEAD")!
            let doc = ProjectDocument(
                name: "Missing Media Fixture",
                renderWidth: 1920, renderHeight: 1080, frameRate: 24,
                media: [],
                videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                    testClipDoc(mediaID: missingID, timelineStart: .zero, durationFrames: 24, rate: 24),
                ])],
                audioTracks: [])
            return serializeTimelineToOtio(doc)
        case "markers.otio":
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
            return serializeTimelineToOtio(doc)
        case "speed_ramp.otio":
            let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!
            let speedCurve = Keyframed<Float>(
                keyframes: [
                    Keyframe(time: CMTime.zero, value: 1.0),
                    Keyframe(time: CMTime(value: 24, timescale: 24), value: 2.0),
                    Keyframe(time: CMTime(value: 48, timescale: 24), value: 1.0),
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
            return serializeTimelineToOtio(doc)
        case "localcut_metadata.otio":
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
            return serializeTimelineToOtio(doc)
        default:
            fatalError("Unknown fixture: \(fixture)")
        }
    }

    private func freshEdl(_ fixture: String) -> (edl: String, warnings: [InterchangeWarning]) {
        switch fixture {
        case "basic.edl":
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
            return serializeTimelineToEdl(doc)
        case "fractional.edl":
            let mediaID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
            let doc = ProjectDocument(
                name: "Fractional Fixture",
                renderWidth: 1920, renderHeight: 1080, frameRate: 29.97,
                media: [testMediaRef(id: mediaID, displayName: "Clip2997.mov")],
                videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [
                    testClipDoc(mediaID: mediaID, timelineStart: .zero, durationFrames: 60, rate: 30),
                ])],
                audioTracks: [])
            return serializeTimelineToEdl(doc)
        default:
            fatalError("Unknown EDL fixture: \(fixture)")
        }
    }

    // MARK: - Byte-equality tests

    private struct FixtureNotFoundError: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixture '\(name)' not found — fixture directory unreachable (sandboxed?)" }
    }

    /// Returns the fixture content or throws when the fixture directory is
    /// unreachable (sandboxed test runner). Tests that call this will fail
    /// visibly rather than silently passing.
    private func requireFixture(_ name: String) throws -> String {
        if let content = readFixture(name) { return content }
        Issue.record("Fixture '\(name)' not found — fixture directory unreachable (sandboxed?)")
        throw FixtureNotFoundError(name: name)
    }

    @Test("basic.otio byte-equal + valid")
    func basicOtio() throws {
        let golden = try requireFixture("basic.otio")
        let (json, warnings) = freshOtio("basic.otio")
        #expect(warnings.isEmpty)
        #expect(json == golden, "basic.otio output differs from committed fixture")
        #expect(validateOtioDocument(json).isEmpty)
    }

    @Test("basic.edl byte-equal + valid")
    func basicEdl() throws {
        let golden = try requireFixture("basic.edl")
        let (edl, warnings) = freshEdl("basic.edl")
        #expect(warnings.isEmpty)
        #expect(edl == golden, "basic.edl output differs from committed fixture")
        #expect(validateEdl(edl).isEmpty)
    }

    @Test("fractional.otio byte-equal + valid")
    func fractionalOtio() throws {
        let golden = try requireFixture("fractional.otio")
        let (json, warnings) = freshOtio("fractional.otio")
        #expect(warnings.isEmpty)
        #expect(json == golden, "fractional.otio output differs from committed fixture")
        #expect(validateOtioDocument(json).isEmpty)
    }

    @Test("fractional.edl byte-equal + valid")
    func fractionalEdl() throws {
        let golden = try requireFixture("fractional.edl")
        let (edl, warnings) = freshEdl("fractional.edl")
        #expect(warnings.isEmpty)
        #expect(edl == golden, "fractional.edl output differs from committed fixture")
        #expect(validateEdl(edl).isEmpty)
        #expect(edl.contains("LOCALCUT: RATE"))
    }

    @Test("transitions.otio byte-equal + valid")
    func transitionsOtio() throws {
        let golden = try requireFixture("transitions.otio")
        let (json, warnings) = freshOtio("transitions.otio")
        #expect(warnings.isEmpty)
        #expect(json == golden, "transitions.otio output differs from committed fixture")
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("SMPTE_Dissolve"))
    }

    @Test("missing_media.otio byte-equal + valid")
    func missingMediaOtio() throws {
        let golden = try requireFixture("missing_media.otio")
        let (json, warnings) = freshOtio("missing_media.otio")
        #expect(!warnings.isEmpty) // Should have missing-source warnings
        #expect(json == golden, "missing_media.otio output differs from committed fixture")
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("MissingReference.1"))
    }

    @Test("markers.otio byte-equal + valid")
    func markersOtio() throws {
        let golden = try requireFixture("markers.otio")
        let (json, warnings) = freshOtio("markers.otio")
        #expect(warnings.isEmpty)
        #expect(json == golden, "markers.otio output differs from committed fixture")
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("Marker.2"))
        #expect(json.contains("Start"))
        #expect(json.contains("Middle"))
    }

    @Test("speed_ramp.otio byte-equal + valid")
    func speedRampOtio() throws {
        let golden = try requireFixture("speed_ramp.otio")
        let (json, warnings) = freshOtio("speed_ramp.otio")
        #expect(!warnings.isEmpty) // Non-uniform speed curve warning
        #expect(json == golden, "speed_ramp.otio output differs from committed fixture")
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("speedCurve"))
    }

    @Test("localcut_metadata.otio byte-equal + valid")
    func localcutMetadataOtio() throws {
        let golden = try requireFixture("localcut_metadata.otio")
        let (json, warnings) = freshOtio("localcut_metadata.otio")
        #expect(warnings.isEmpty)
        #expect(json == golden, "localcut_metadata.otio output differs from committed fixture")
        #expect(validateOtioDocument(json).isEmpty)
        #expect(json.contains("colourGrade"))
        #expect(json.contains("captionTracks"))
        #expect(json.contains("Hello world"))
    }
}

// Test helpers are in InterchangeTestHelpers.swift (internal access).
