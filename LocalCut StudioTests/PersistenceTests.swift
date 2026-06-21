import Testing
import Foundation
import AVFoundation
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
            transition: TransitionDoc(type: TransitionType.wipe.rawValue, duration: CMTimeCode(time(1))))

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
            effects: [.lut(bookmark: Data([0x01]))],
            transition: TransitionDoc(type: TransitionType.crossDissolve.rawValue,
                                      duration: CMTimeCode(time(1))))
        let clip = doc.makeClip()
        #expect(clip.mediaID == mediaID)
        #expect(clip.sourceStart == time(2))
        #expect(clip.duration == time(3))
        #expect(clip.timelineStart == time(5))
        #expect(clip.opacity == 0.75)
        #expect(clip.effects == [.lut(bookmark: Data([0x01]))])
        #expect(clip.transition?.type == .crossDissolve)
        #expect(clip.transition?.duration == time(1))
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
