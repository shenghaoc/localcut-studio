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

    @Test("Chained transitions ripple cumulatively without negative ranges")
    func chainedTransitionsRippleCumulatively() {
        let media = UUID()
        let a = Clip(mediaID: media, sourceStart: .zero, duration: time(4), timelineStart: .zero)
        var b = Clip(mediaID: media, sourceStart: .zero, duration: time(4), timelineStart: time(4))
        b.transition = Transition(duration: time(1))
        var c = Clip(mediaID: media, sourceStart: .zero, duration: time(4), timelineStart: time(8))
        c.transition = Transition(duration: time(1))

        let track = videoTrack([a, b, c])
        let cuts = TransitionLayout.cuts(videoTracks: [track])
        let placements = TransitionLayout.placements(for: [a, b, c], cuts: cuts)

        let pa = placements.first { $0.id == a.id }!
        let pb = placements.first { $0.id == b.id }!
        let pc = placements.first { $0.id == c.id }!

        #expect(pa.effectiveStart == .zero)        // [0, 4]
        #expect(pb.effectiveStart == time(3))      // 4 - 1  → [3, 7]
        #expect(pc.effectiveStart == time(6))      // 8 - 2  → [6, 10]
        // Every placement keeps a positive duration and forward order.
        for p in placements { #expect(p.effectiveEnd > p.effectiveStart) }
        #expect(pa.effectiveStart < pb.effectiveStart)
        #expect(pb.effectiveStart < pc.effectiveStart)
        // A and C must not overlap (so they can share a comp track safely here).
        #expect(pa.effectiveEnd <= pc.effectiveStart)
    }

    @Test("Coincident cuts across tracks merge into one (no double-ripple)")
    func coincidentCutsMerge() {
        let media = UUID()
        func track(_ name: String, transition seconds: Double) -> Track {
            let t = Track(name: name, kind: .video)
            var b = Clip(mediaID: media, sourceStart: .zero, duration: time(5), timelineStart: time(5))
            b.transition = Transition(duration: time(seconds))
            t.clips = [
                Clip(mediaID: media, sourceStart: .zero, duration: time(5), timelineStart: .zero),
                b,
            ]
            return t
        }
        // Two video tracks both cut at t=5, with different overlaps.
        let cuts = TransitionLayout.cuts(videoTracks: [track("V1", transition: 1), track("V2", transition: 2)])
        #expect(cuts.count == 1)               // merged, not double-counted
        #expect(cuts.first?.overlap == time(2)) // max of the two overlaps
        // The merged cut shifts a later time by exactly one overlap.
        #expect(TransitionLayout.shift(at: time(5), cuts: cuts) == time(2))
    }

    // MARK: - Spanning-clip splitting (A/V sync across cuts)

    @Test("A clip that spans a transition cut splits and ripples each side")
    func spanningClipSplitsAtCut() {
        // A continuous audio bed [0,10] under a video cut at 5s with a 1s overlap.
        let bed = Clip(mediaID: UUID(), sourceStart: .zero, duration: time(10), timelineStart: .zero)
        let cuts = [TransitionLayout.Cut(time: time(5), overlap: time(1))]
        let pieces = TransitionLayout.pieces(for: bed, overlap: .zero, cuts: cuts)

        #expect(pieces.count == 2)
        // Head piece [0,5] stays put.
        #expect(pieces[0].effectiveStart == .zero)
        #expect(pieces[0].sourceRange.start == .zero)
        #expect(pieces[0].sourceRange.duration == time(5))
        // Tail piece reads source [5,10] but is rippled 1s earlier to stay in sync.
        #expect(pieces[1].effectiveStart == time(4))
        #expect(pieces[1].sourceRange.start == time(5))
        #expect(pieces[1].sourceRange.duration == time(5))
        // The bed now ends at 9s, matching the shortened video timeline.
        #expect(pieces[1].effectiveEnd == time(9))
    }

    @Test("A clip clear of every cut is not split")
    func clipClearOfCutsNotSplit() {
        let clip = Clip(mediaID: UUID(), sourceStart: .zero, duration: time(4), timelineStart: time(6))
        let cuts = [TransitionLayout.Cut(time: time(5), overlap: time(1))]
        let pieces = TransitionLayout.pieces(for: clip, overlap: .zero, cuts: cuts)
        #expect(pieces.count == 1)
        #expect(pieces[0].effectiveStart == time(5)) // 6 - shift(1)
    }

    // MARK: - Render planning (chained / overlapping transitions)

    private func segment(track: CMPersistentTrackID, start: Double,
                         transition: (Double, Double, TransitionType)? = nil) -> CompositionBuilder.VisibleSegment {
        CompositionBuilder.VisibleSegment(
            compTrackID: track, start: start,
            transitionStart: transition?.0, transitionEnd: transition?.1, transitionType: transition?.2)
    }

    @Test("A single visible clip plans one layer")
    func planSingleLayer() {
        let plan = CompositionBuilder.planUnits(visible: [segment(track: 1, start: 0)], midpoint: 2)
        #expect(plan == [.layer(1)])
    }

    @Test("Two overlapping clips plan a transition between predecessor and incoming")
    func planTwoClipTransition() {
        let visible = [
            segment(track: 1, start: 0),
            segment(track: 2, start: 4, transition: (4, 5, .crossDissolve)),
        ]
        let plan = CompositionBuilder.planUnits(visible: visible, midpoint: 4.5)
        #expect(plan == [.transition(outgoing: 1, incoming: 2, type: .crossDissolve)])
    }

    @Test("Triple overlap keeps the top clip: earlier clip renders under the latest transition")
    func planChainedTripleOverlap() {
        // A (track1) under, B (track2) transitions from A, C (track3) transitions from B.
        let visible = [
            segment(track: 1, start: 0),
            segment(track: 2, start: 1, transition: (1, 4, .crossDissolve)),
            segment(track: 3, start: 2, transition: (2, 5, .wipe)),
        ]
        let plan = CompositionBuilder.planUnits(visible: visible, midpoint: 3)
        // Topmost active transition (B→C) wins; A is drawn underneath, C is not dropped.
        #expect(plan == [.layer(1), .transition(outgoing: 2, incoming: 3, type: .wipe)])
    }

    @Test("Adjacent transition windows never overlap (chained clamp)")
    func chainedTransitionsClampAgainstSharedHandle() {
        // Three 5s clips with 4s transitions at both cuts. The middle clip's
        // incoming window already consumes 4s of its 5s, leaving 1s for the next.
        let media = UUID()
        let a = Clip(mediaID: media, sourceStart: .zero, duration: time(5), timelineStart: .zero)
        var b = Clip(mediaID: media, sourceStart: .zero, duration: time(5), timelineStart: time(5))
        b.transition = Transition(duration: time(4))
        var c = Clip(mediaID: media, sourceStart: .zero, duration: time(5), timelineStart: time(10))
        c.transition = Transition(duration: time(4))

        let cuts = TransitionLayout.cuts(videoTracks: [videoTrack([a, b, c])])
        let placements = TransitionLayout.placements(for: [a, b, c], cuts: cuts)
        let pb = placements.first { $0.id == b.id }!
        let pc = placements.first { $0.id == c.id }!

        #expect(pb.overlap == time(4))
        #expect(pc.overlap == time(1)) // clamped: 5 - 4 already used by B's incoming
        // The two transition windows abut but do not overlap.
        #expect(pb.transitionRange!.end <= pc.transitionRange!.start)
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

    @Test("Deleting a transition's predecessor clears the now-orphaned transition")
    func deletePredecessorClearsTransition() {
        let (model, aID, bID) = makeModel()
        model.selectedClipID = bID
        model.addTransitionToSelectedClip()

        model.selectedClipID = aID
        model.deleteSelectedClip()

        #expect(model.clip(for: bID)?.transition == nil)
        #expect(model.selectedTransitionClipID == nil)
    }

    @Test("Moving a clip drops its incoming transition (cut destroyed)")
    func moveClipClearsTransition() {
        let (model, _, bID) = makeModel()
        model.selectedClipID = bID
        model.addTransitionToSelectedClip()

        let trackID = model.project.videoTracks.first!.id
        model.moveClip(id: bID, toTrack: trackID, start: time(20))

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

    // MARK: - T1.2 Opacity-ramp layer instructions

    @Test("crossDissolveLayerInstructions: ramps opacity from 1→0 (outgoing) and 0→1 (incoming) across the overlap")
    func crossDissolveLayerRamps() {
        let overlap = CMTimeRange(start: time(5), duration: time(1))
        let pair = CompositionBuilder.crossDissolveLayerInstructions(
            outgoingTrackID: 100,
            incomingTrackID: 200,
            outgoingTransform: .identity,
            incomingTransform: .identity,
            overlap: overlap)

        #expect(pair.outgoing.trackID == 100)
        #expect(pair.incoming.trackID == 200)

        // The opacity ramp is the spec-faithful expression of the cross-dissolve.
        // `getOpacityRamp` returns the ramp endpoints + range into out-params;
        // we verify outgoing ramps 1 → 0 and incoming ramps 0 → 1 over the
        // exact overlap window.
        var outStart: Float = -1
        var outEnd: Float = -1
        var outRange = CMTimeRange.zero
        let outFound = pair.outgoing.getOpacityRamp(
            for: overlap.start,
            startOpacity: &outStart,
            endOpacity: &outEnd,
            timeRange: &outRange)
        #expect(outFound)
        #expect(outStart == 1)
        #expect(outEnd == 0)
        #expect(outRange == overlap)

        var inStart: Float = -1
        var inEnd: Float = -1
        var inRange = CMTimeRange.zero
        let inFound = pair.incoming.getOpacityRamp(
            for: overlap.start,
            startOpacity: &inStart,
            endOpacity: &inEnd,
            timeRange: &inRange)
        #expect(inFound)
        #expect(inStart == 0)
        #expect(inEnd == 1)
        #expect(inRange == overlap)
    }

}
