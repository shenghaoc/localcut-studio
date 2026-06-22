import Testing
import AVFoundation
@testable import LocalCut_Studio

// MARK: - Model (feature-markers R1, R5.1)

@MainActor
@Suite("Timeline markers — model")
struct MarkersModelTests {

    @Test("addMarkerAtPlayhead inserts a marker at the current playhead")
    func addMarkerAtPlayhead() {
        let model = EditorModel()
        model.currentTime = 2.5
        model.addMarkerAtPlayhead()
        #expect(model.project.markers.count == 1)
        #expect(abs(model.project.markers[0].time.seconds - 2.5) < 1e-6)
        #expect(model.project.markers[0].name == "Marker")
    }

    @Test("Out-of-order playhead inserts keep the marker list sorted by time")
    func insertsStaySorted() {
        let model = EditorModel()
        // Add at 5s, then 1s, then 3s.
        for seconds in [5.0, 1.0, 3.0] {
            model.currentTime = seconds
            model.addMarkerAtPlayhead()
        }
        let times = model.project.markers.map { $0.time.seconds }
        #expect(times == times.sorted())
        #expect(times.count == 3)
    }

    @Test("Two markers requested at the exact same time are both kept, distinct by id")
    func sameTimeAllowed() {
        let model = EditorModel()
        model.currentTime = 1.0
        model.addMarkerAtPlayhead()
        model.addMarkerAtPlayhead()
        #expect(model.project.markers.count == 2)
        #expect(model.project.markers[0].id != model.project.markers[1].id)
    }

    @Test("Auto-naming avoids duplicate default labels")
    func defaultNameUnique() {
        let model = EditorModel()
        for seconds in [0.0, 1.0, 2.0] {
            model.currentTime = seconds
            model.addMarkerAtPlayhead()
        }
        let names = Set(model.project.markers.map(\.name))
        #expect(names.count == 3)
        #expect(names.contains("Marker"))
    }

    @Test("Project.duration ignores markers past the last clip")
    func durationIgnoresMarkers() {
        let project = Project()
        project.markers = [TimelineMarker(time: CMTime(seconds: 99, preferredTimescale: 600))]
        // No clips → duration is zero even though a marker sits at 99s.
        #expect(project.duration.seconds == 0)
    }
}

// MARK: - Persistence (R2, R5.2, R5.3)

@MainActor
@Suite("Timeline markers — persistence")
struct MarkersPersistenceTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    @Test("ProjectDocument round-trips markers losslessly, including optional colour")
    func roundTrip() throws {
        let project = Project()
        let withColour = TimelineMarker(
            time: time(1.25),
            name: "Verse",
            colour: RGBAColour(red: 1, green: 0.4, blue: 0.2, alpha: 1))
        let plain = TimelineMarker(time: time(4.5), name: "Chorus")
        project.markers = [withColour, plain]

        let data = try ProjectDocument(project: project).encoded()
        let back = try ProjectDocument(data: data)
        #expect(back.markers.count == 2)
        #expect(back.markers[0].id == withColour.id)
        #expect(back.markers[0].name == "Verse")
        #expect(back.markers[0].colour == withColour.colour)
        #expect(abs(back.markers[0].time.seconds - 1.25) < 1e-6)
        #expect(back.markers[1].id == plain.id)
        #expect(back.markers[1].colour == nil)
    }

    @Test("Legacy document without `markers` decodes to an empty array")
    func legacyDocDecodes() throws {
        let legacyJSON = """
        {
          "name": "Old",
          "schemaVersion": 2,
          "renderWidth": 1920, "renderHeight": 1080, "frameRate": 30,
          "media": [], "videoTracks": [], "audioTracks": [], "captionTracks": []
        }
        """
        let doc = try ProjectDocument(data: Data(legacyJSON.utf8))
        #expect(doc.markers.isEmpty)
    }

    @Test("ProjectDocument: schema is v3 once markers ship")
    func schemaVersionBumped() {
        #expect(ProjectDocument.currentSchemaVersion >= 3)
    }

    @Test("TimelineMarker time persists via the CMTimeCode rational shape")
    func cmTimeShape() throws {
        let marker = TimelineMarker(
            time: CMTime(value: 7, timescale: 3),
            name: "Odd timescale")
        let data = try JSONEncoder().encode(marker)
        let json = try #require(String(data: data, encoding: .utf8))
        // Round-trip preserves the exact rational, not a Double-of-seconds.
        let back = try JSONDecoder().decode(TimelineMarker.self, from: data)
        #expect(back.time.value == 7)
        #expect(back.time.timescale == 3)
        // The on-disk shape nests time as {value, timescale}, not a flat number.
        #expect(json.contains("\"timescale\""))
    }
}

// MARK: - Editor commands + undo (R3, R5.4)

@MainActor
@Suite("Timeline markers — editor commands")
struct MarkersEditorTests {

    private func makeModelWithMarker(at seconds: Double = 1.0) -> (EditorModel, TimelineMarker.ID) {
        let model = EditorModel()
        model.currentTime = seconds
        model.addMarkerAtPlayhead()
        return (model, model.project.markers[0].id)
    }

    @Test("Delete then undo restores the marker with its original UUID")
    func deleteUndoRestoresMarker() {
        let (model, markerID) = makeModelWithMarker()
        #expect(model.project.markers.count == 1)
        #expect(model.canUndo)

        model.removeMarker(id: markerID)
        #expect(model.project.markers.isEmpty)
        #expect(model.selectedMarkerID == nil)
        #expect(model.canUndo)

        model.undo()
        #expect(model.project.markers.count == 1)
        #expect(model.project.markers[0].id == markerID, "Undo must restore the original UUID")
    }

    @Test("Add then undo removes the marker; redo brings it back")
    func addUndoRedo() {
        let model = EditorModel()
        model.currentTime = 0.5
        model.addMarkerAtPlayhead()
        let id = model.project.markers[0].id

        model.undo()
        #expect(model.project.markers.isEmpty)
        #expect(model.canRedo)

        model.redo()
        #expect(model.project.markers.count == 1)
        #expect(model.project.markers[0].id == id)
    }

    @Test("Rename folds into one undo step when typed character-by-character")
    func renameCoalesces() {
        let (model, markerID) = makeModelWithMarker()
        let originalName = model.project.markers[0].name

        // Simulate the inspector text field firing one update per keystroke.
        for prefix in ["B", "Be", "Bea", "Beat"] {
            model.updateMarkerCoalesced(id: markerID, name: prefix)
        }
        model.commitCoalescedUndo()

        #expect(model.project.markers[0].name == "Beat")
        model.undo()
        #expect(model.project.markers[0].name == originalName)
    }

    @Test("renameMarker registers an undo step with the right action name")
    func renameUndoLabel() {
        let (model, markerID) = makeModelWithMarker()
        model.renameMarker(id: markerID, to: "Hook")
        #expect(model.project.markers[0].name == "Hook")
        #expect(model.undoTitle.contains("Rename Marker"))
    }

    @Test("seekToMarker moves the playhead and selects the marker")
    func seekToMarkerSelects() {
        let model = EditorModel()
        model.currentTime = 1.0
        model.addMarkerAtPlayhead()
        let id = model.project.markers[0].id
        model.selectedMarkerID = nil
        model.currentTime = 0
        model.seekToMarker(id: id)
        #expect(model.selectedMarkerID == id)
        #expect(abs(model.currentTime - 1.0) < 1e-6)
    }

    @Test("seekToMarker bypasses the totalDuration clamp for markers past project end (Codex review #5)")
    func seekPastProjectEnd() {
        let model = EditorModel()
        // No clips → `totalDuration` stays 0. A marker at 12 s is allowed
        // (markers don't extend `Project.duration`) and clicking its row in
        // the inspector must still park the playhead at 12 s, not at 0.
        model.project.markers = [TimelineMarker(
            time: CMTime(seconds: 12, preferredTimescale: 600),
            name: "Tail")]
        let id = model.project.markers[0].id
        model.seekToMarker(id: id)
        #expect(abs(model.currentTime - 12) < 1e-6)
        #expect(model.selectedMarkerID == id)
    }

    @Test("selectMarker(id:) clears clip / transition / media focus on every UI surface (post-revision review P1)")
    func selectMarkerFunnelExclusivity() {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = CMTime(seconds: 5, preferredTimescale: 600)
        model.project.mediaItems.append(media)
        let clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: CMTime(seconds: 5, preferredTimescale: 600),
                        timelineStart: .zero)
        model.project.videoTracks.first!.clips.append(clip)
        model.project.markers = [TimelineMarker(
            time: CMTime(seconds: 1, preferredTimescale: 600), name: "M")]
        let markerID = model.project.markers[0].id

        // Pretend the user previously selected a clip + media (inspector
        // shows them), then taps a marker row in the inspector.
        model.selectedClipID = clip.id
        model.selectedMediaID = media.id
        model.selectMarker(id: markerID)

        #expect(model.selectedMarkerID == markerID)
        #expect(model.selectedClipID == nil)
        #expect(model.selectedTransitionClipID == nil)
        #expect(model.selectedMediaID == nil)
    }

    @Test("Adding a marker clears clip / transition / media focus (Gemini review #4, Codex review #2)")
    func markerSelectionIsMutuallyExclusive() {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = CMTime(seconds: 5, preferredTimescale: 600)
        model.project.mediaItems.append(media)
        let clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: CMTime(seconds: 5, preferredTimescale: 600),
                        timelineStart: .zero)
        model.project.videoTracks.first!.clips.append(clip)
        model.selectedClipID = clip.id
        model.selectedMediaID = media.id

        model.currentTime = 1
        model.addMarkerAtPlayhead()

        // After the add, only the marker should be selected.
        #expect(model.selectedMarkerID != nil)
        #expect(model.selectedClipID == nil)
        #expect(model.selectedMediaID == nil)
        #expect(model.selectedTransitionClipID == nil)
    }

    @Test("ProjectState snapshot survives applyState restore with identity intact")
    func snapshotRoundTrip() {
        let model = EditorModel()
        model.currentTime = 2
        model.addMarkerAtPlayhead()
        let originalID = model.project.markers[0].id
        let snapshot = model.captureState()

        model.project.markers.removeAll()
        #expect(model.project.markers.isEmpty)
        model.applyState(snapshot)
        #expect(model.project.markers.count == 1)
        #expect(model.project.markers[0].id == originalID)
    }
}
