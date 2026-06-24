import Testing
import AVFoundation
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Trim & Drag")
struct TrimAndDragTests {

    // MARK: - Helpers

    /// Default project.frameRate is 30 fps, so min clip = CMTime(value:1, timescale:30).
    private static let oneFrame = CMTime(value: 1, timescale: 30)

    private func makeModel(clipDuration: Double = 10, sourceStart: Double = 0) -> (EditorModel, Clip.ID) {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = CMTime(seconds: clipDuration, preferredTimescale: 600)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        let clip = Clip(
            mediaID: media.id,
            sourceStart: CMTime(seconds: sourceStart, preferredTimescale: 600),
            duration: CMTime(seconds: clipDuration - sourceStart, preferredTimescale: 600),
            timelineStart: .zero)
        model.project.videoTracks.first!.clips.append(clip)
        return (model, clip.id)
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Trim left edge

    @Test("Trim left edge moves sourceStart and timelineStart, preserves end")
    func trimLeftBasic() {
        let (model, clipID) = makeModel()
        let originalEnd = model.project.videoTracks.first!.clips[0].timelineEnd

        model.trimClip(id: clipID, edge: .left, to: time(3))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.timelineStart.seconds == 3)
        #expect(clip.sourceStart.seconds == 3)
        #expect(clip.timelineEnd == originalEnd)
    }

    @Test("Trim left edge clamps to source start (can't go before 0)")
    func trimLeftClampsToSourceStart() {
        let (model, clipID) = makeModel()

        model.trimClip(id: clipID, edge: .left, to: time(-5))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.timelineStart.seconds == 0)
        #expect(clip.sourceStart.seconds == 0)
    }

    @Test("Trim left edge clamps to minimum clip duration (one render frame)")
    func trimLeftClampsToMinDuration() {
        let (model, clipID) = makeModel(clipDuration: 10)

        model.trimClip(id: clipID, edge: .left, to: time(100))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.duration == Self.oneFrame)
    }

    @Test("Trim left edge stops at previous clip boundary")
    func trimLeftClampsToNeighbour() throws {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let track = model.project.videoTracks.first!

        let clip1 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: .zero)
        let clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: time(5))
        track.clips = [clip1, clip2]

        model.trimClip(id: clip2.id, edge: .left, to: time(3))

        let trimmed = try #require(track.clips.first { $0.id == clip2.id })
        #expect(trimmed.timelineStart == time(5))
    }

    // MARK: - Trim right edge

    @Test("Trim right edge adjusts duration only")
    func trimRightBasic() {
        let (model, clipID) = makeModel()

        model.trimClip(id: clipID, edge: .right, to: time(5))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.duration.seconds == 5)
        #expect(clip.timelineStart == .zero)
        #expect(clip.sourceStart == .zero)
    }

    @Test("Trim right edge clamps to source duration")
    func trimRightClampsToSource() {
        let (model, clipID) = makeModel(clipDuration: 10)

        model.trimClip(id: clipID, edge: .right, to: time(20))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.duration.seconds == 10)
    }

    @Test("Trim right edge clamps to minimum duration (one render frame)")
    func trimRightClampsToMinDuration() {
        let (model, clipID) = makeModel()

        model.trimClip(id: clipID, edge: .right, to: time(-5))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.duration == Self.oneFrame)
    }

    @Test("Trim right edge stops at next clip boundary")
    func trimRightClampsToNeighbour() throws {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let track = model.project.videoTracks.first!

        let clip1 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: .zero)
        let clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: time(5))
        track.clips = [clip1, clip2]

        model.trimClip(id: clip1.id, edge: .right, to: time(8))

        let trimmed = try #require(track.clips.first { $0.id == clip1.id })
        #expect(trimmed.duration == time(5))
    }

    // MARK: - Move

    @Test("Move clip changes timelineStart")
    func moveBasic() {
        let (model, clipID) = makeModel()

        let trackID = model.project.videoTracks.first!.id
        model.moveClip(id: clipID, toTrack: trackID, start: time(5))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.timelineStart.seconds == 5)
    }

    @Test("Move clip clamps to zero")
    func moveClampsToZero() {
        let (model, clipID) = makeModel()

        let trackID = model.project.videoTracks.first!.id
        model.moveClip(id: clipID, toTrack: trackID, start: time(-3))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.timelineStart.seconds == 0)
    }

    @Test("Move rejects cross-kind tracks (video to audio)")
    func moveRejectsCrossKind() {
        let (model, clipID) = makeModel()
        let audioTrackID = model.project.audioTracks.first!.id

        model.moveClip(id: clipID, toTrack: audioTrackID, start: time(0))

        #expect(model.project.videoTracks.first!.clips.count == 1)
        #expect(model.project.audioTracks.first!.clips.isEmpty)
    }

    @Test("Move resolves overlap by snapping to nearest gap")
    func moveResolvesOverlap() throws {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)

        let track = model.project.videoTracks.first!

        let clip1 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: .zero)
        let clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: time(5))
        track.clips = [clip1, clip2]

        model.moveClip(id: clip2.id, toTrack: track.id, start: time(2))

        let moved = try #require(track.clips.first { $0.id == clip2.id })
        #expect(moved.timelineStart == time(5))
    }

    // MARK: - Snap targets

    @Test("Snap targets include zero, playhead, and clip boundaries")
    func snapTargetsContents() {
        let (model, _) = makeModel(clipDuration: 10)
        model.currentTime = 3.0

        let targets = model.snapTargets()

        #expect(targets.contains(.zero))
        #expect(targets.contains(time(3)))
        #expect(targets.contains(time(0)))
        #expect(targets.contains(time(10)))
    }

    @Test("Snap targets exclude only the dragged clip, not shared boundaries")
    func snapTargetsPreserveSharedBoundaries() {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let track = model.project.videoTracks.first!

        let clip1 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: .zero)
        let clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: time(5))
        track.clips = [clip1, clip2]

        // Excluding clip2 should keep clip1's end at 5s (shared boundary).
        let targets = model.snapTargets(excluding: clip2.id)
        #expect(targets.contains(time(5)))
    }

    @Test("Snap targets convert the effective playhead through transition ripples")
    func snapTargetsConvertPlayheadThroughTransitions() {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let track = model.project.videoTracks.first!

        let clip1 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: .zero)
        var clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: time(5))
        clip2.transition = Transition(duration: time(1))
        track.clips = [clip1, clip2]

        // After the one-second transition ripple, effective 6s is authored 7s.
        model.currentTime = 6
        #expect(model.resolveSnap(candidate: time(6.96), excluding: clip2.id, threshold: 0.1) == time(7))

        // Inside the transition window, the same effective playhead exposes
        // both authored sides so each neighbour can snap to what the user sees.
        model.currentTime = 4.5
        let targets = model.snapTargets()
        #expect(targets.contains(time(4.5)))
        #expect(targets.contains(time(5.5)))
        #expect(model.resolveSnap(candidate: time(5.46), excluding: clip2.id, threshold: 0.1) == time(5.5))
        #expect(model.resolveSnap(candidate: time(4.54), excluding: clip1.id, threshold: 0.1) == time(4.5))
    }

    @Test("Resolve snap returns candidate when nothing is close")
    func resolveSnapNoMatch() {
        let (model, clipID) = makeModel(clipDuration: 10)
        model.pixelsPerSecond = 80

        let candidate = time(5.5)
        let result = model.resolveSnap(candidate: candidate, excluding: clipID)

        #expect(result == candidate)
    }

    @Test("Resolve snap snaps to nearby target")
    func resolveSnapMatch() {
        let (model, clipID) = makeModel(clipDuration: 10)
        model.pixelsPerSecond = 80

        let media = model.project.mediaItems[0]
        let track = model.project.videoTracks.first!
        let clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(3), timelineStart: time(15))
        track.clips.append(clip2)

        let result = model.resolveSnap(candidate: time(14.95), excluding: clipID, threshold: 0.1)
        #expect(result == time(15))
    }

    @Test("Resolve snap considers trailing edge when offset provided")
    func resolveSnapTrailingEdge() {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = time(20)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let track = model.project.videoTracks.first!

        let clip1 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(5), timelineStart: .zero)
        let clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(3), timelineStart: time(10))
        track.clips = [clip1, clip2]

        // Drag clip2 so its trailing edge (start+3) is near clip1's end (5).
        // candidate=1.96 → trailing=4.96, within 0.1s of 5 → snaps start to 2.
        let result = model.resolveSnap(
            candidate: time(1.96), excluding: clip2.id,
            trailingEdgeOffset: time(3), threshold: 0.1)
        #expect(result == time(2))
    }
}
