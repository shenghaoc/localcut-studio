import Testing
import AVFoundation
@testable import LocalCut_Studio

@MainActor
@Suite("Transitions")
struct TransitionsTests {

    // MARK: - Helpers

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Two butt-adjacent video clips A[0,5] and B[5,5] on one track, with a
    /// transition of `transitionSeconds` into B.
    private func makeAdjacentPair(
        aDuration: Double = 5, bDuration: Double = 5,
        transition transitionSeconds: Double? = 1) -> (a: Clip, b: Clip) {
        let media = UUID()
        let a = Clip(mediaID: media, sourceStart: .zero,
                     duration: time(aDuration), timelineStart: .zero)
        var b = Clip(mediaID: media, sourceStart: .zero,
                     duration: time(bDuration), timelineStart: time(aDuration))
        if let transitionSeconds {
            b.transition = Transition(duration: time(transitionSeconds))
        }
        return (a, b)
    }

    private func videoTrack(_ clips: [Clip]) -> Track {
        let track = Track(name: "V1", kind: .video)
        track.clips = clips
        return track
    }

    // MARK: - Overlap derivation & clamping (T1.4, R1.3, R4.1)

    @Test("Overlap equals the requested duration when both neighbours are longer")
    func overlapUsesRequestedDuration() {
        let (a, b) = makeAdjacentPair(transition: 1)
        #expect(TransitionLayout.effectiveOverlap(into: b, previous: a) == time(1))
    }

    @Test("Overlap clamps to the shorter neighbour")
    func overlapClampsToShorterNeighbour() {
        let (a, b) = makeAdjacentPair(bDuration: 3, transition: 2)
        // min(requested 2, prev 5, clip 3) == 2 (clip is 3, still ≥ 2)
        #expect(TransitionLayout.effectiveOverlap(into: b, previous: a) == time(2))

        let (a2, b2) = makeAdjacentPair(aDuration: 1.5, transition: 2)
        // prev is only 1.5s → overlap clamps to 1.5
        #expect(TransitionLayout.effectiveOverlap(into: b2, previous: a2) == time(1.5))
    }

    @Test("No transition yields zero overlap")
    func noTransitionNoOverlap() {
        let (a, b) = makeAdjacentPair(transition: nil)
        #expect(TransitionLayout.effectiveOverlap(into: b, previous: a) == .zero)
    }

    @Test("A gap between clips disables the transition overlap")
    func nonAdjacentNoOverlap() {
        var (a, b) = makeAdjacentPair(transition: 1)
        b.timelineStart = time(6) // 1s gap after A ends at 5
        #expect(TransitionLayout.effectiveOverlap(into: b, previous: a) == .zero)
    }

    @Test("Clamping reacts to a later trim that shrinks a neighbour")
    func overlapReactsToTrim() {
        var (a, b) = makeAdjacentPair(transition: 2)
        #expect(TransitionLayout.effectiveOverlap(into: b, previous: a) == time(2))
        // Shrink A to 1s (as a trim would) — overlap must clamp down.
        a.duration = time(1)
        b.timelineStart = time(1) // stays adjacent after the trim
        #expect(TransitionLayout.effectiveOverlap(into: b, previous: a) == time(1))
    }

    // MARK: - Effective placement / time ranges (T1.4, R2.3)

    @Test("Placements ripple the trailing clip earlier by the overlap")
    func placementsRippleByOverlap() {
        let (a, b) = makeAdjacentPair(transition: 1)
        let cuts = TransitionLayout.cuts(videoTracks: [videoTrack([a, b])])
        let placements = TransitionLayout.placements(for: [a, b], cuts: cuts)

        let pa = placements.first { $0.id == a.id }!
        let pb = placements.first { $0.id == b.id }!

        #expect(pa.effectiveStart == .zero)
        #expect(pa.effectiveEnd == time(5))
        #expect(pb.effectiveStart == time(4)) // 5 - 1
        #expect(pb.effectiveEnd == time(9))   // total shortened by 1
        #expect(pb.overlap == time(1))
    }

    @Test("Transition range is the overlap interval [effectiveStart, +overlap]")
    func transitionRangeMatchesOverlap() {
        let (a, b) = makeAdjacentPair(transition: 1)
        let cuts = TransitionLayout.cuts(videoTracks: [videoTrack([a, b])])
        let placements = TransitionLayout.placements(for: [a, b], cuts: cuts)
        let pb = placements.first { $0.id == b.id }!

        let range = pb.transitionRange!
        #expect(range.start == time(4))
        #expect(range.duration == time(1))
        #expect(range.end == time(5))
        // The outgoing clip still covers up to 5, so they overlap on [4, 5].
        let pa = placements.first { $0.id == a.id }!
        #expect(pa.effectiveEnd == time(5))
    }

    @Test("Outgoing clip without a transition has no transition range")
    func outgoingHasNoTransitionRange() {
        let (a, b) = makeAdjacentPair(transition: 1)
        let cuts = TransitionLayout.cuts(videoTracks: [videoTrack([a, b])])
        let placements = TransitionLayout.placements(for: [a, b], cuts: cuts)
        let pa = placements.first { $0.id == a.id }!
        #expect(pa.transitionRange == nil)
    }

    @Test("Linked audio ripples identically to video so A/V stays in sync")
    func audioRipplesWithVideo() {
        let (a, b) = makeAdjacentPair(transition: 1)
        let videoCuts = TransitionLayout.cuts(videoTracks: [videoTrack([a, b])])
        // Audio clips share the same boundaries but carry no transition.
        let audioA = Clip(mediaID: UUID(), sourceStart: .zero, duration: time(5), timelineStart: .zero)
        let audioB = Clip(mediaID: UUID(), sourceStart: .zero, duration: time(5), timelineStart: time(5))
        let audioPlacements = TransitionLayout.placements(for: [audioA, audioB], cuts: videoCuts)
        let pb = audioPlacements.first { $0.id == audioB.id }!
        #expect(pb.effectiveStart == time(4)) // same ripple as the video B
    }

    // MARK: - EditorModel integration (T1.4, R3, R4)

    private func makeModel() -> (EditorModel, Clip.ID, Clip.ID) {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let track = model.project.videoTracks.first!
        let a = Clip(mediaID: media.id, sourceStart: .zero, duration: time(5), timelineStart: .zero)
        let b = Clip(mediaID: media.id, sourceStart: .zero, duration: time(5), timelineStart: time(5))
        track.clips = [a, b]
        return (model, a.id, b.id)
    }

    @Test("Can add a transition only on a clip that follows an adjacent one")
    func canAddTransitionGating() {
        let (model, aID, bID) = makeModel()
        model.selectedClipID = bID
        #expect(model.canAddTransitionAtSelection)
        model.selectedClipID = aID
        #expect(!model.canAddTransitionAtSelection) // no predecessor
    }

    @Test("Adding a transition attaches it to the trailing clip and selects it")
    func addTransitionSelectsIt() {
        let (model, _, bID) = makeModel()
        model.selectedClipID = bID
        model.addTransitionToSelectedClip()

        #expect(model.clip(for: bID)?.transition != nil)
        #expect(model.selectedTransitionClipID == bID)
        #expect(model.selectedClipID == nil)
        // Default 0.5s fits within the 5s overlap.
        #expect(model.clip(for: bID)?.transition?.duration == Transition.defaultDuration)
    }

    @Test("Default transition duration clamps to a short overlap")
    func addTransitionClampsDefault() {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let track = model.project.videoTracks.first!
        let a = Clip(mediaID: media.id, sourceStart: .zero, duration: time(0.3), timelineStart: .zero)
        let b = Clip(mediaID: media.id, sourceStart: .zero, duration: time(0.3), timelineStart: time(0.3))
        track.clips = [a, b]

        model.selectedClipID = b.id
        model.addTransitionToSelectedClip()
        // 0.5s default clamps to the 0.3s available overlap.
        #expect(model.clip(for: b.id)?.transition?.duration == time(0.3))
    }

    @Test("Selected transition max duration is the shorter neighbour")
    func selectedTransitionMaxDuration() {
        let (model, _, bID) = makeModel()
        model.selectedClipID = bID
        model.addTransitionToSelectedClip()
        #expect(model.selectedTransitionMaxDuration == time(5))
    }

    @Test("Removing a transition restores the plain cut")
    func removeTransitionRestoresCut() {
        let (model, _, bID) = makeModel()
        model.selectedClipID = bID
        model.addTransitionToSelectedClip()
        model.removeSelectedTransition()

        #expect(model.clip(for: bID)?.transition == nil)
        #expect(model.selectedTransitionClipID == nil)
    }

    @Test("Editing the selected transition updates type and duration")
    func editSelectedTransition() {
        let (model, _, bID) = makeModel()
        model.selectedClipID = bID
        model.addTransitionToSelectedClip()

        model.updateSelectedTransition { $0.type = .wipe }
        model.updateSelectedTransition { $0.duration = self.time(2) }

        #expect(model.clip(for: bID)?.transition?.type == .wipe)
        #expect(model.clip(for: bID)?.transition?.duration == time(2))
    }
}
