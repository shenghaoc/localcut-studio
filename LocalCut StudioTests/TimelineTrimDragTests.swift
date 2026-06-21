import Testing
import AVFoundation
import CoreGraphics
@testable import LocalCut_Studio

// MARK: - T1.4 Unit tests

// ── Track overlap resolution ──

@Test("Track.nearestNonOverlappingStart returns desired when no overlap")
func noOverlap() {
    let track = Track(name: "V1", kind: .video)
    track.clips = [
        Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600), timelineStart: .zero),
    ]
    let result = track.nearestNonOverlappingStart(for: CMTime(seconds: 3, preferredTimescale: 600), desired: CMTime(seconds: 6, preferredTimescale: 600))
    #expect(CMTimeCompare(result, CMTime(seconds: 6, preferredTimescale: 600)) == 0)
}

@Test("Track.nearestNonOverlappingStart pushes past overlapping clip")
func overlapPushesPast() {
    let track = Track(name: "V1", kind: .video)
    let existing = Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600), timelineStart: .zero)
    track.clips = [existing]

    let result = track.nearestNonOverlappingStart(for: CMTime(seconds: 3, preferredTimescale: 600), desired: CMTime(seconds: 2, preferredTimescale: 600))
    #expect(CMTimeCompare(result, CMTime(seconds: 5, preferredTimescale: 600)) == 0)
}

@Test("Track.nearestNonOverlappingStart handles multiple clips")
func multipleClipsOverlap() {
    let track = Track(name: "V1", kind: .video)
    track.clips = [
        Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600), timelineStart: .zero),
        Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600), timelineStart: CMTime(seconds: 5, preferredTimescale: 600)),
    ]

    let result = track.nearestNonOverlappingStart(for: CMTime(seconds: 3, preferredTimescale: 600), desired: CMTime(seconds: 2, preferredTimescale: 600))
    #expect(CMTimeCompare(result, CMTime(seconds: 8, preferredTimescale: 600)) == 0)
}

// ── Snap targets ──

@MainActor
@Test("snapTargets includes zero, playhead, and all clip boundaries")
func snapTargetsBasic() {
    let model = EditorModel()

    let mediaID = UUID()
    model.project.mediaItems.append(MediaItem(url: URL(fileURLWithPath: "/tmp/test.mov")))
    model.project.mediaItems[0].duration = CMTime(seconds: 60, preferredTimescale: 600)

    let track = Track(name: "V1", kind: .video)
    track.clips = [
        Clip(mediaID: mediaID, sourceStart: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600), timelineStart: .zero),
        Clip(mediaID: mediaID, sourceStart: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600), timelineStart: CMTime(seconds: 15, preferredTimescale: 600)),
    ]
    model.project.videoTracks = [track]
    model.currentTime = 12

    let targets = model.snapTargets()
    #expect(targets.contains(.zero))
    #expect(targets.contains(CMTime(seconds: 12, preferredTimescale: 600)))
    #expect(targets.contains(CMTime(seconds: 10, preferredTimescale: 600)))
    #expect(targets.contains(CMTime(seconds: 15, preferredTimescale: 600)))
    #expect(targets.contains(CMTime(seconds: 20, preferredTimescale: 600)))
}

@MainActor
@Test("snapTargets excludes given clip ID")
func snapTargetsExcludesClip() {
    let model = EditorModel()
    let track = Track(name: "V1", kind: .video)
    let clip0 = Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600), timelineStart: .zero)
    let clip1 = Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600), timelineStart: CMTime(seconds: 15, preferredTimescale: 600))
    track.clips = [clip0, clip1]
    model.project.videoTracks = [track]

    let targets = model.snapTargets(excluding: clip0.id)
    // Zero is always included (hardcoded snap target).
    #expect(targets.contains(.zero))
    // First clip's boundaries should be excluded.
    #expect(!targets.contains(clip0.timelineEnd))
    // Second clip's boundaries should be included.
    #expect(targets.contains(CMTime(seconds: 15, preferredTimescale: 600)))
    #expect(targets.contains(CMTime(seconds: 20, preferredTimescale: 600)))
}

// ── Resolve snap ──

@MainActor
@Test("resolveSnap returns candidate when nothing nearby")
func snapNoTarget() {
    let model = EditorModel()
    let candidate = CMTime(seconds: 7.5, preferredTimescale: 600)
    let result = model.resolveSnap(candidate: candidate, thresholdSeconds: 0.5)
    #expect(CMTimeCompare(result, candidate) == 0)
}

@MainActor
@Test("resolveSnap snaps to nearest within threshold")
func snapWithinThreshold() {
    let model = EditorModel()
    let track = Track(name: "V1", kind: .video)
    track.clips = [
        Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600), timelineStart: .zero),
    ]
    model.project.videoTracks = [track]

    let candidate = CMTime(seconds: 9.8, preferredTimescale: 600)
    let result = model.resolveSnap(candidate: candidate, thresholdSeconds: 0.5)
    #expect(CMTimeCompare(result, CMTime(seconds: 10, preferredTimescale: 600)) == 0)
}

// ── Trim logic ──

@MainActor
@Test("trimClip left edge adjusts timelineStart and sourceStart")
func trimLeft() {
    let model = EditorModel()
    let url = URL(fileURLWithPath: "/tmp/test.mov")
    let media = MediaItem(url: url)
    media.duration = CMTime(seconds: 60, preferredTimescale: 600)
    model.project.mediaItems.append(media)

    let clip = Clip(mediaID: media.id, sourceStart: CMTime(seconds: 5, preferredTimescale: 600),
                    duration: CMTime(seconds: 20, preferredTimescale: 600),
                    timelineStart: CMTime(seconds: 10, preferredTimescale: 600))
    let track = Track(name: "V1", kind: .video)
    track.clips = [clip]
    model.project.videoTracks = [track]
    model.selectedClipID = clip.id

    model.trimClip(id: clip.id, edge: .left, to: CMTime(seconds: 12, preferredTimescale: 600))

    let updated = track.clips[0]
    #expect(CMTimeCompare(updated.timelineStart, CMTime(seconds: 12, preferredTimescale: 600)) == 0)
    #expect(CMTimeCompare(updated.sourceStart, CMTime(seconds: 7, preferredTimescale: 600)) == 0)
    #expect(CMTimeCompare(updated.duration, CMTime(seconds: 18, preferredTimescale: 600)) == 0)
}

@MainActor
@Test("trimClip right edge adjusts duration only")
func trimRight() {
    let model = EditorModel()
    let url = URL(fileURLWithPath: "/tmp/test.mov")
    let media = MediaItem(url: url)
    media.duration = CMTime(seconds: 60, preferredTimescale: 600)
    model.project.mediaItems.append(media)

    let clip = Clip(mediaID: media.id, sourceStart: CMTime(seconds: 5, preferredTimescale: 600),
                    duration: CMTime(seconds: 20, preferredTimescale: 600),
                    timelineStart: CMTime(seconds: 10, preferredTimescale: 600))
    let track = Track(name: "V1", kind: .video)
    track.clips = [clip]
    model.project.videoTracks = [track]
    model.selectedClipID = clip.id

    model.trimClip(id: clip.id, edge: .right, to: CMTime(seconds: 25, preferredTimescale: 600))

    let updated = track.clips[0]
    #expect(CMTimeCompare(updated.timelineStart, CMTime(seconds: 10, preferredTimescale: 600)) == 0)
    #expect(CMTimeCompare(updated.sourceStart, CMTime(seconds: 5, preferredTimescale: 600)) == 0)
    #expect(CMTimeCompare(updated.duration, CMTime(seconds: 15, preferredTimescale: 600)) == 0)
}

@MainActor
@Test("trimClip left edge clamps to source bounds")
func trimLeftClamped() {
    let model = EditorModel()
    let url = URL(fileURLWithPath: "/tmp/test.mov")
    let media = MediaItem(url: url)
    media.duration = CMTime(seconds: 30, preferredTimescale: 600)
    model.project.mediaItems.append(media)

    let clip = Clip(mediaID: media.id, sourceStart: .zero,
                    duration: CMTime(seconds: 30, preferredTimescale: 600),
                    timelineStart: .zero)
    let track = Track(name: "V1", kind: .video)
    track.clips = [clip]
    model.project.videoTracks = [track]
    model.selectedClipID = clip.id

    // Try to trim past start — should be clamped.
    model.trimClip(id: clip.id, edge: .left, to: CMTime(seconds: -5, preferredTimescale: 600))

    let updated = track.clips[0]
    #expect(CMTimeCompare(updated.timelineStart, .zero) == 0)
    #expect(CMTimeCompare(updated.sourceStart, .zero) == 0)
}
