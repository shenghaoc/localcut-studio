import Testing
import Foundation
import AVFoundation
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Project Persistence")
struct PersistenceTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - CMTime coding (R1.1, exactness)

    @Test("CMTimeCode preserves value/timescale exactly through coding")
    func cmTimeCodeRoundTrips() throws {
        let original = CMTime(value: 1001, timescale: 30_000)   // a non-round rational
        let code = CMTimeCode(original)
        #expect(code.value == 1001)
        #expect(code.timescale == 30_000)
        #expect(code.cmTime == original)

        let data = try JSONEncoder().encode(code)
        let decoded = try JSONDecoder().decode(CMTimeCode.self, from: data)
        #expect(decoded == code)
        #expect(decoded.cmTime == original)
    }

    @Test("Non-numeric CMTime collapses to a safe zero")
    func cmTimeCodeHandlesIndefinite() {
        #expect(CMTimeCode(.indefinite).cmTime == .zero)
        #expect(CMTimeCode(.invalid).cmTime == .zero)
        #expect(CMTimeCode(CMTime(value: 1000, timescale: -600)).cmTime == .zero)
    }

    @Test("Decoded CMTimeCode rejects corrupt timescales")
    func decodedCMTimeCodeRejectsCorruptTimescale() throws {
        for rawTimescale in [0, -600] {
            let data = Data(#"{"value":1000,"timescale":\#(rawTimescale)}"#.utf8)
            let decoded = try JSONDecoder().decode(CMTimeCode.self, from: data)
            let time = decoded.cmTime

            #expect(decoded.value == 0)
            #expect(decoded.timescale == 600)
            #expect(time == .zero)
        }
    }

    // MARK: - Document round-trip equality (T1.4, R1.1)

    private func sampleDocument() -> ProjectDocument {
        let mediaID = UUID()
        let media = MediaRef(
            id: mediaID,
            displayName: "Clip A",
            bookmark: Data([0x01, 0x02, 0x03]),
            duration: CMTimeCode(time(10)),
            naturalWidth: 1920, naturalHeight: 1080,
            preferredTransform: TransformCode(CGAffineTransform(rotationAngle: 1.2)),
            hasVideo: true, hasAudio: false)

        let grade = ColourGrade(exposure: 0.5, contrast: 1.1, saturation: 1.25,
                                temperatureOffset: 200, tintOffset: -30)
        let clip = ClipDoc(
            mediaID: mediaID,
            sourceStart: CMTimeCode(time(1)),
            duration: CMTimeCode(time(5)),
            timelineStart: CMTimeCode(.zero),
            opacity: 0.5,
            effects: [.colourGrade(grade), .lut(bookmark: Data([0xAA, 0xBB]))],
            transition: TransitionDoc(type: TransitionType.wipe.rawValue,
                                      duration: CMTimeCode(time(1)),
                                      wipeAngle: Transition.radians(fromDegrees: 90)))

        return ProjectDocument(
            name: "My Project",
            renderWidth: 1280, renderHeight: 720, frameRate: 24,
            media: [media],
            videoTracks: [TrackDoc(name: "V1", kind: "video", isMuted: false, clips: [clip])],
            audioTracks: [TrackDoc(name: "A1", kind: "audio", isMuted: true, clips: [])])
    }

    @Test("ProjectDocument encodes and decodes to an equal value")
    func documentRoundTripEquality() throws {
        let doc = sampleDocument()
        let decoded = try ProjectDocument(data: doc.encoded())
        #expect(decoded == doc)
    }

    @Test("Encoded document carries the current schema version")
    func documentCarriesSchemaVersion() throws {
        let doc = sampleDocument()
        #expect(doc.schemaVersion == ProjectDocument.currentSchemaVersion)
        let decoded = try ProjectDocument(data: doc.encoded())
        #expect(decoded.schemaVersion == ProjectDocument.currentSchemaVersion)
    }

    // MARK: - Forward-compatible decoding (R4.2)

    @Test("Unknown keys and a higher schema version still decode")
    func decodesUnknownKeysAndFutureVersion() throws {
        let mediaID = UUID()
        // A document from a hypothetical future schema: extra top-level key,
        // higher schemaVersion, and a clip missing opacity/effects/transition.
        let json = """
        {
          "schemaVersion": 99,
          "name": "Future",
          "renderWidth": 1920, "renderHeight": 1080, "frameRate": 30,
          "futureFeature": { "enabled": true },
          "media": [],
          "videoTracks": [
            { "name": "V1", "kind": "video", "clips": [
              { "mediaID": "\(mediaID.uuidString)",
                "sourceStart": { "value": 0, "timescale": 600 },
                "duration": { "value": 600, "timescale": 600 },
                "timelineStart": { "value": 0, "timescale": 600 } }
            ] }
          ],
          "audioTracks": []
        }
        """
        let decoded = try ProjectDocument(data: Data(json.utf8))
        #expect(decoded.schemaVersion == 99)
        #expect(decoded.name == "Future")
        // Missing optional fields fall back to defaults rather than throwing.
        #expect(decoded.videoTracks[0].isMuted == false)
        let clip = decoded.videoTracks[0].clips[0]
        #expect(clip.opacity == 1)
        #expect(clip.effects.isEmpty)
        #expect(clip.transition == nil)
    }

    @Test("Missing top-level fields fall back to defaults")
    func decodesWithDefaults() throws {
        let decoded = try ProjectDocument(data: Data("{}".utf8))
        #expect(decoded.frameRate == 30)
        #expect(decoded.renderWidth == 1920)
        #expect(decoded.media.isEmpty)
        #expect(decoded.videoTracks.isEmpty)
    }

    // MARK: - Snapshot (Project → Document) (T1.2)

    @Test("Snapshotting a project captures media, clips, effects and transitions")
    func snapshotProject() {
        let project = Project()
        project.name = "Snap"
        project.renderSize = CGSize(width: 1280, height: 720)
        project.frameRate = 24

        let media = MediaItem(url: URL(fileURLWithPath: "/tmp/sample.mov"))
        media.bookmark = Data([0x09, 0x09])
        media.duration = time(8)
        media.hasVideo = true
        media.naturalSize = CGSize(width: 1920, height: 1080)
        project.mediaItems.append(media)

        var clip = Clip(mediaID: media.id, sourceStart: .zero, duration: time(4),
                        timelineStart: .zero, opacity: 0.5, effects: [.colourGrade(.neutral)])
        clip.transition = Transition(type: .wipe, duration: time(1))
        clip.transition?.wipeAngle = Transition.radians(fromDegrees: 135)
        project.videoTracks.first!.clips.append(clip)

        let doc = ProjectDocument(project: project)
        #expect(doc.name == "Snap")
        #expect(doc.renderWidth == 1280)
        #expect(doc.frameRate == 24)
        #expect(doc.media.count == 1)
        #expect(doc.media[0].id == media.id)
        #expect(doc.media[0].bookmark == Data([0x09, 0x09]))
        #expect(doc.media[0].duration.cmTime == time(8))

        let captured = doc.videoTracks[0].clips[0]
        #expect(captured.mediaID == media.id)
        #expect(captured.opacity == 0.5)
        #expect(captured.duration.cmTime == time(4))
        #expect(captured.effects == [.colourGrade(.neutral)])
        #expect(captured.transition?.type == TransitionType.wipe.rawValue)
        #expect(captured.transition?.duration.cmTime == time(1))
        #expect(captured.transition?.wipeAngle == Transition.radians(fromDegrees: 135))
    }

    // MARK: - Reconstruction (Document → runtime) (T1.2)

    @Test("Reconstructing a clip from a ClipDoc preserves every field")
    func reconstructClip() {
        let mediaID = UUID()
        let doc = ClipDoc(
            mediaID: mediaID,
            sourceStart: CMTimeCode(time(2)),
            duration: CMTimeCode(time(3)),
            timelineStart: CMTimeCode(time(5)),
            opacity: 0.75,
            geometry: ClipGeometry(positionOffset: CGSize(width: 120, height: -80),
                                   scale: 0.42,
                                   mask: .circle),
            effects: [.lut(bookmark: Data([0x01]))],
            transition: TransitionDoc(type: TransitionType.crossDissolve.rawValue,
                                      duration: CMTimeCode(time(1)),
                                      wipeAngle: Transition.radians(fromDegrees: 270)))
        let clip = doc.makeClip()
        #expect(clip.mediaID == mediaID)
        #expect(clip.sourceStart == time(2))
        #expect(clip.duration == time(3))
        #expect(clip.timelineStart == time(5))
        #expect(clip.opacity == 0.75)
        #expect(clip.geometry.positionOffset == CGSize(width: 120, height: -80))
        #expect(clip.geometry.scale == 0.42)
        #expect(clip.geometry.mask == .circle)
        #expect(clip.effects == [.lut(bookmark: Data([0x01]))])
        #expect(clip.transition?.type == .crossDissolve)
        #expect(clip.transition?.duration == time(1))
        #expect(clip.transition?.wipeAngle == Transition.radians(fromDegrees: 270))
    }

    @Test("Legacy transition documents default the wipe angle")
    func legacyTransitionDefaultsWipeAngle() throws {
        let json = """
        {
          "type": "wipe",
          "duration": { "value": 600, "timescale": 600 }
        }
        """
        let transition = try JSONDecoder().decode(TransitionDoc.self, from: Data(json.utf8))
        #expect(transition.makeTransition().type == .wipe)
        #expect(transition.makeTransition().duration == time(1))
        #expect(transition.makeTransition().wipeAngle == Transition.defaultWipeAngle)
    }

    @Test("Saving carries unresolved media refs so a save-before-relink keeps them")
    func saveKeepsUnresolvedMedia() {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/tmp/a.mov"))
        media.bookmark = Data([0x01])
        media.duration = time(5)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        let missing = MediaRef(
            id: UUID(), displayName: "Missing", bookmark: Data([0x02]),
            duration: CMTimeCode(time(3)), naturalWidth: 1920, naturalHeight: 1080,
            preferredTransform: TransformCode(.identity), hasVideo: true, hasAudio: false)
        model.unresolvedMedia = [missing]

        let doc = model.makeDocumentForSave()
        #expect(doc.media.count == 2)
        #expect(doc.media.contains { $0.id == media.id })
        #expect(doc.media.contains { $0.id == missing.id })
    }

    @Test("Project snapshot survives a full JSON round trip")
    func projectSnapshotRoundTrip() throws {
        let project = Project()
        let media = MediaItem(url: URL(fileURLWithPath: "/tmp/a.mov"))
        media.bookmark = Data([0x05])
        media.duration = time(6)
        media.hasVideo = true
        project.mediaItems.append(media)
        project.videoTracks.first!.clips.append(
            Clip(mediaID: media.id, sourceStart: .zero, duration: time(6), timelineStart: .zero))

        let doc = ProjectDocument(project: project)
        let decoded = try ProjectDocument(data: doc.encoded())
        #expect(decoded == doc)
    }
}
