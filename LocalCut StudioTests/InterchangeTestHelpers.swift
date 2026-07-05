import Foundation
import CoreMedia
@testable import LocalCutCore
@testable import LocalCut_Studio

// Shared test helpers for interchange tests.
// Access level is `internal` (default) so all files in the test target can use them.

func makeTestDoc(frameRate: Double,
                 name: String = "Test Project",
                 media: [MediaRef] = [],
                 videoClips: Int = 0,
                 audioClips: Int = 0,
                 clips: [ClipDoc]? = nil,
                 markers: [TimelineMarker] = [],
                 captionTracks: [CaptionTrackDoc] = []) -> ProjectDocument {
    let videoTrackClips = clips ?? (0..<videoClips).map { i in
        testClipDoc(mediaID: media.first?.id ?? UUID(),
                    timelineStart: CMTime(value: Int64(i * 24), timescale: 24),
                    durationFrames: 24, rate: 24)
    }
    let audioTrackClips = (0..<audioClips).map { i in
        testClipDoc(mediaID: media.first?.id ?? UUID(),
                    timelineStart: CMTime(value: Int64(i * 24), timescale: 24),
                    durationFrames: 24, rate: 24)
    }
    return ProjectDocument(
        name: name,
        renderWidth: 1920,
        renderHeight: 1080,
        frameRate: frameRate,
        media: media,
        videoTracks: videoTrackClips.isEmpty ? [] : [
            TrackDoc(name: "V1", kind: "video", isMuted: false, clips: videoTrackClips),
        ],
        audioTracks: audioTrackClips.isEmpty ? [] : [
            TrackDoc(name: "A1", kind: "audio", isMuted: false, clips: audioTrackClips),
        ],
        captionTracks: captionTracks,
        markers: markers)
}

func testMediaRef(id: UUID = UUID(),
                  displayName: String = "TestMedia.mov",
                  bookmark: Data = Data([0x01]),
                  bundleRelativePath: String? = nil) -> MediaRef {
    MediaRef(
        id: id,
        displayName: displayName,
        bookmark: bookmark,
        duration: CMTimeCode(CMTime(value: 240, timescale: 24)),
        naturalWidth: 1920,
        naturalHeight: 1080,
        preferredTransform: TransformCode(.identity),
        hasVideo: true,
        hasAudio: true,
        bundleRelativePath: bundleRelativePath)
}

func testClipDoc(mediaID: UUID = UUID(),
                 timelineStart: CMTime,
                 durationFrames: Int,
                 rate: Int,
                 transition: TransitionDoc? = nil,
                 effects: [Effect] = [],
                 opacity: Float = 1,
                 speedCurve: Keyframed<Float>? = nil) -> ClipDoc {
    ClipDoc(
        mediaID: mediaID,
        sourceStart: CMTimeCode(CMTime.zero),
        duration: CMTimeCode(CMTime(value: Int64(durationFrames), timescale: Int32(rate))),
        timelineStart: CMTimeCode(timelineStart),
        opacity: opacity,
        effects: effects,
        transition: transition,
        speedCurve: speedCurve)
}
