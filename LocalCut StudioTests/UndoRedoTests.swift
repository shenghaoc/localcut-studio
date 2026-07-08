import Testing
import Foundation
import AVFoundation
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Undo / Redo")
struct UndoRedoTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A model with one 10s video clip on V1.
    private func makeModel(clipDuration: Double = 10) -> (EditorModel, Clip.ID) {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(clipDuration)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        let clip = Clip(mediaID: media.id, sourceStart: .zero,
                        duration: time(clipDuration), timelineStart: .zero)
        model.project.videoTracks.first!.clips.append(clip)
        return (model, clip.id)
    }

    private func videoClips(_ model: EditorModel) -> [Clip] {
        model.project.videoTracks.first!.clips
    }

    @Test("EditorModel: rebuild refreshes the clip lookup index after direct track replacement")
    func rebuildRefreshesClipIndex() async {
        let model = EditorModel()
        let clip = Clip(mediaID: UUID(), sourceStart: .zero,
                        duration: time(1), timelineStart: .zero)
        model.project.videoTracks[0].clips = [clip]

        await model.rebuild()

        #expect(model.clip(for: clip.id)?.id == clip.id)
        #expect(model.track(for: clip.id)?.id == model.project.videoTracks[0].id)
    }

    @Test("EditorModel: applyState refreshes the clip lookup index")
    func applyStateRefreshesClipIndex() {
        let (model, clipID) = makeModel()
        let state = model.captureState()
        model.project.videoTracks[0].clips.removeAll()
        model.rebuildClipIndex()
        #expect(model.clip(for: clipID) == nil)

        model.applyState(state)

        #expect(model.clip(for: clipID)?.id == clipID)
        #expect(model.track(for: clipID)?.id == model.project.videoTracks[0].id)
    }

    // MARK: - Discrete edits (R3.1, R3.3)

    @Test("Delete then undo restores the clip; redo removes it again")
    func deleteUndoRedo() {
        let (model, clipID) = makeModel()
        model.selectedClipID = clipID

        model.deleteSelectedClip()
        #expect(videoClips(model).isEmpty)
        #expect(model.canUndo)
        #expect(model.isDirty)

        model.undo()
        #expect(videoClips(model).count == 1)
        #expect(videoClips(model)[0].id == clipID)
        #expect(model.canRedo)

        model.redo()
        #expect(videoClips(model).isEmpty)
    }

    @Test("Removing media is undoable, dirty, and drops dependent clips")
    func removeMediaUndoRedo() {
        let (model, clipID) = makeModel()
        let media = model.project.mediaItems[0]
        model.selectedMediaID = media.id
        model.selectedClipID = clipID

        model.removeMedia(itemID: media.id)
        #expect(model.project.mediaItems.isEmpty)
        #expect(videoClips(model).isEmpty)
        #expect(model.selectedMediaID == nil)
        #expect(model.selectedClipID == nil)
        #expect(model.isDirty)
        #expect(model.canUndo)

        model.undo()
        #expect(model.project.mediaItems.map(\.id) == [media.id])
        #expect(videoClips(model).map(\.id) == [clipID])
        #expect(model.canRedo)

        model.redo()
        #expect(model.project.mediaItems.isEmpty)
        #expect(videoClips(model).isEmpty)
    }

    @Test("Removing one duplicate media keeps shared URL access until the last item is gone")
    func removeMediaKeepsSharedURLAccess() {
        let model = EditorModel()
        let url = URL(fileURLWithPath: "/tmp/shared-source.mov")
        let first = MediaItem(url: url)
        let second = MediaItem(url: url)
        model.project.mediaItems.append(contentsOf: [first, second])
        model.accessedURLs.insert(url)

        model.removeMedia(itemID: first.id)
        #expect(model.project.mediaItems.map(\.id) == [second.id])
        #expect(model.accessedURLs.contains(url))

        model.removeMedia(itemID: second.id)
        #expect(model.project.mediaItems.isEmpty)
        #expect(!model.accessedURLs.contains(url))
    }

    @Test("Undo removes regular tracks added by a single action")
    func addedTrackUndoRedo() {
        let model = EditorModel()
        let originalVideoTrackIDs = model.project.videoTracks.map(\.id)

        model.performUndoable("Add Recording") {
            let track = Track(name: "Screen", kind: .video)
            model.project.videoTracks.append(track)
        }
        #expect(model.project.videoTracks.count == originalVideoTrackIDs.count + 1)
        #expect(model.canUndo)

        model.undo()
        #expect(model.project.videoTracks.map(\.id) == originalVideoTrackIDs)
        #expect(model.canRedo)

        model.redo()
        #expect(model.project.videoTracks.count == originalVideoTrackIDs.count + 1)
        #expect(model.project.videoTracks.last?.name == "Screen")
    }

    @Test("Undo label reflects the action name")
    func undoLabel() {
        let (model, clipID) = makeModel()
        model.selectedClipID = clipID
        model.deleteSelectedClip()
        #expect(model.undoTitle.contains("Delete Clip"))
        model.undo()
        #expect(model.redoTitle.contains("Delete Clip"))
    }

    @Test("Split then undo collapses back to a single clip")
    func splitUndo() {
        let (model, clipID) = makeModel()
        model.selectedClipID = clipID
        model.currentTime = 4

        model.splitSelectedClipAtPlayhead()
        #expect(videoClips(model).count == 2)

        model.undo()
        #expect(videoClips(model).count == 1)
        #expect(videoClips(model)[0].duration == time(10))
    }

    @Test("Changing render size is undoable")
    func renderSizeUndo() {
        let (model, _) = makeModel()
        #expect(model.project.renderSize == CGSize(width: 1920, height: 1080))

        model.setRenderSize(CGSize(width: 1280, height: 720))
        #expect(model.project.renderSize == CGSize(width: 1280, height: 720))

        model.undo()
        #expect(model.project.renderSize == CGSize(width: 1920, height: 1080))
    }

    // MARK: - Coalesced gestures (R3.1)

    @Test("A trim gesture is one undo step that restores the original clip")
    func trimUndoIsOneStep() {
        let (model, clipID) = makeModel()
        let original = videoClips(model)[0]

        // Simulate a drag: several trim updates in one gesture.
        model.trimClip(id: clipID, edge: .right, to: time(8))
        model.trimClip(id: clipID, edge: .right, to: time(6))
        model.trimClip(id: clipID, edge: .right, to: time(5))
        #expect(videoClips(model)[0].duration == time(5))

        // One undo reverts the whole gesture (undo() flushes the coalesced step).
        model.undo()
        #expect(videoClips(model)[0].duration == original.duration)
        #expect(videoClips(model)[0].sourceStart == original.sourceStart)
        #expect(!model.canUndo)
    }

    @Test("Adjacent coalesced gestures on different clips stay separate undo steps")
    func adjacentCoalescedGesturesSeparate() {
        let (model, clipA) = makeModel()
        let media = model.project.mediaItems[0]
        let clipB = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(10), timelineStart: time(10))
        model.project.videoTracks.first!.clips.append(clipB)

        func clip(_ id: Clip.ID) -> Clip { videoClips(model).first { $0.id == id }! }

        model.trimClip(id: clipB.id, edge: .right, to: time(15))   // gesture on B
        model.trimClip(id: clipA, edge: .right, to: time(5))       // different target → ends B's gesture
        #expect(clip(clipA).duration == time(5))
        #expect(clip(clipB.id).duration == time(5))

        model.undo()                                               // undoes only A
        #expect(clip(clipA).duration == time(10))
        #expect(clip(clipB.id).duration == time(5))

        model.undo()                                               // undoes B
        #expect(clip(clipB.id).duration == time(10))
    }

    @Test("An opacity drag coalesces into a single undo step")
    func opacityUndo() {
        let (model, clipID) = makeModel()
        model.selectedClipID = clipID

        model.updateSelectedClipCoalesced("Adjust Opacity") { $0.opacity = 0.8 }
        model.updateSelectedClipCoalesced("Adjust Opacity") { $0.opacity = 0.5 }
        #expect(videoClips(model)[0].opacity == 0.5)

        model.undo()
        #expect(videoClips(model)[0].opacity == 1)
        #expect(!model.canUndo)
    }

    @Test("A no-op coalesced gesture leaves the document clean; a real one dirties it")
    func noOpCoalescedGestureNotDirty() {
        let (model, clipID) = makeModel()
        #expect(!model.isDirty)

        // Right-trim to the clip's existing end: clamps to no net change.
        model.trimClip(id: clipID, edge: .right, to: time(10))
        model.commitCoalescedUndo()
        #expect(videoClips(model)[0].duration == time(10))
        #expect(!model.isDirty)        // no change → not dirty
        #expect(!model.canUndo)        // and no undo step registered

        // A gesture that actually changes the clip does dirty the document.
        model.trimClip(id: clipID, edge: .right, to: time(6))
        model.commitCoalescedUndo()
        #expect(videoClips(model)[0].duration == time(6))
        #expect(model.isDirty)
        #expect(model.canUndo)
    }

    // MARK: - Sequencing

    @Test("Undo/redo walks a multi-step history in order")
    func multiStepHistory() {
        let (model, clipID) = makeModel()
        model.selectedClipID = clipID

        model.setRenderSize(CGSize(width: 1280, height: 720))   // step 1
        model.currentTime = 5
        model.splitSelectedClipAtPlayhead()                     // step 2
        #expect(videoClips(model).count == 2)
        #expect(model.project.renderSize.width == 1280)

        model.undo()                                            // undo split
        #expect(videoClips(model).count == 1)
        #expect(model.project.renderSize.width == 1280)

        model.undo()                                            // undo render size
        #expect(model.project.renderSize.width == 1920)
        #expect(!model.canUndo)

        model.redo()                                            // redo render size
        #expect(model.project.renderSize.width == 1280)
    }

    @Test("Undo preserves the unresolved-media relink queue")
    func unresolvedMediaSurvivesUndo() {
        let (model, clipID) = makeModel()
        let ref = MediaRef(
            id: UUID(), displayName: "Missing", bookmark: Data([0x01]),
            duration: CMTimeCode(time(5)), naturalWidth: 1920, naturalHeight: 1080,
            preferredTransform: TransformCode(.identity), hasVideo: true, hasAudio: false)
        model.unresolvedMedia = [ref]
        model.selectedClipID = clipID

        // The delete's `before` snapshot must capture the relink queue...
        model.deleteSelectedClip()
        #expect(model.unresolvedMedia == [ref])

        // ...so that undoing a later, unrelated change can never silently drop it.
        model.unresolvedMedia = []
        model.undo()
        #expect(model.unresolvedMedia == [ref])
        #expect(videoClips(model).count == 1)
    }

    @Test("Undo restores a removed transition")
    func transitionRemoveUndo() {
        let (model, _) = makeModel()
        // Add a second adjacent clip so a transition can be hosted.
        let media = model.project.mediaItems[0]
        let clipB = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: time(10))
        model.project.videoTracks.first!.clips.append(clipB)

        model.selectedClipID = clipB.id
        model.addTransitionToSelectedClip()
        #expect(model.clip(for: clipB.id)?.transition != nil)

        model.selectedTransitionClipID = clipB.id
        model.removeSelectedTransition()
        #expect(model.clip(for: clipB.id)?.transition == nil)

        model.undo()   // undo the removal
        #expect(model.clip(for: clipB.id)?.transition != nil)
    }
}
