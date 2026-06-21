import Testing
import AVFoundation
@testable import LocalCut_Studio

@MainActor
@Suite("Trim & Drag")
struct TrimAndDragTests {

    // MARK: - Helpers

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

    @Test("Trim left edge clamps to minimum clip duration")
    func trimLeftClampsToMinDuration() {
        let (model, clipID) = makeModel(clipDuration: 10)

        model.trimClip(id: clipID, edge: .left, to: time(100))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.duration > .zero)
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

    @Test("Trim right edge clamps to minimum duration")
    func trimRightClampsToMinDuration() {
        let (model, clipID) = makeModel()

        model.trimClip(id: clipID, edge: .right, to: time(-5))

        let clip = model.project.videoTracks.first!.clips[0]
        #expect(clip.duration > .zero)
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

        // Clip should still be on the video track.
        #expect(model.project.videoTracks.first!.clips.count == 1)
        #expect(model.project.audioTracks.first!.clips.isEmpty)
    }

    @Test("Move resolves overlap by snapping to nearest gap")
    func moveResolvesOverlap() {
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

        // Try to move clip2 to overlap with clip1.
        model.moveClip(id: clip2.id, toTrack: track.id, start: time(2))

        // After overlap resolution, clip2 should not overlap clip1.
        let moved = track.clips.first { $0.id == clip2.id }!
        let other = track.clips.first { $0.id == clip1.id }!
        #expect(moved.timelineStart >= other.timelineEnd || moved.timelineEnd <= other.timelineStart)
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

        // Threshold is 8px / 80pps = 0.1s. Place candidate at 9.95s — within 0.05s of clip end at 10s.
        let candidate = time(9.95)
        let result = model.resolveSnap(candidate: candidate, excluding: clipID, threshold: 0.1)

        // Should snap to the playhead at 0 or the clip boundary — but clip boundaries are excluded for the dragged clip.
        // So it should snap to .zero only if within threshold, which it's not. So stays at candidate.
        // Actually let's test with a non-excluded target: add another clip.
        let media = model.project.mediaItems[0]
        let track = model.project.videoTracks.first!
        let clip2 = Clip(mediaID: media.id, sourceStart: .zero,
                         duration: time(3), timelineStart: time(15))
        track.clips.append(clip2)

        let result2 = model.resolveSnap(candidate: time(14.95), excluding: clipID, threshold: 0.1)
        #expect(result2 == time(15))
    }
}
