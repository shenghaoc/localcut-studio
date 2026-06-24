import Testing
import Foundation
import CoreMedia
import CoreGraphics
import LocalCutCore

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func clip(start: Double,
                  duration: Double,
                  sourceStart: Double = 0,
                  mediaID: UUID = UUID(),
                  transition: LocalCutCore.Transition? = nil) -> Clip {
    Clip(mediaID: mediaID,
         sourceStart: time(sourceStart),
         duration: time(duration),
         timelineStart: time(start),
         transition: transition)
}

private func segment(track id: Int32,
                     start: Double,
                     transitionStart: Double? = nil,
                     transitionEnd: Double? = nil,
                     type: TransitionType? = nil) -> VisibleSegment {
    VisibleSegment(compTrackID: id,
                   start: start,
                   transitionStart: transitionStart,
                   transitionEnd: transitionEnd,
                   transitionType: type,
                   transitionWipeAngle: nil)
}

private func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 0.0001) -> Bool {
    abs(a - b) <= tolerance
}

@Test("Keyframed<Float>: sorted insertion, interpolation, and exact-time replacement")
func keyframedFloatSortedInterpolationAndReplacement() {
    var value = Keyframed<Float>(defaultValue: 0)
    value.addKeyframe(at: time(2), value: 1)
    value.addKeyframe(at: time(0), value: 0)

    #expect(value.keyframes.map { $0.time } == [time(0), time(2)])
    #expect(approximatelyEqual(Double(value.value(at: time(1))), 0.5))

    value.addKeyframe(at: time(2), value: 0.25)
    #expect(value.keyframes.count == 2)
    #expect(approximatelyEqual(Double(value.value(at: time(3))), 0.25))
}

@Test("TransitionLayout: project-wide cuts ripple placements across tracks")
func transitionLayoutRipplesPlacements() {
    let incomingTransition = LocalCutCore.Transition(type: .crossDissolve, duration: time(2))
    let a = clip(start: 0, duration: 5)
    let b = clip(start: 5, duration: 5, transition: incomingTransition)
    let audio = clip(start: 5, duration: 5)

    let cuts = TransitionLayout.cuts(videoTracks: [[a, b]])
    #expect(cuts == [TransitionLayout.Cut(time: time(5), overlap: time(2))])

    let videoPlacements = TransitionLayout.placements(for: [a, b], cuts: cuts)
    #expect(videoPlacements.map(\.effectiveStart) == [time(0), time(3)])

    let audioPlacement = TransitionLayout.placements(for: [audio], cuts: cuts)
    #expect(audioPlacement.first?.effectiveStart == time(3))
    #expect(TransitionLayout.authoredTimes(forEffective: time(4), cuts: cuts) == [time(4), time(6)])
}

@Test("RenderPlanning: active incoming transition replaces its outgoing layer")
func renderPlanningPromotesTransitionUnit() {
    let visible = [
        segment(track: 1, start: 0),
        segment(track: 2, start: 4, transitionStart: 4, transitionEnd: 5, type: .crossDissolve),
    ]

    #expect(planUnits(visible: visible, midpoint: 4.5) == [
        .transition(outgoing: 1, incoming: 2, type: .crossDissolve, wipeAngle: 0),
    ])
    #expect(planUnits(visible: visible, midpoint: 5.1) == [.layer(1), .layer(2)])
}

@Test("RenderPlanning: sub-ramp volumes map a slice onto the full ramp")
func renderPlanningSubRampVolumes() {
    let full = CMTimeRange(start: time(10), duration: time(10))
    let slice = CMTimeRange(start: time(12.5), duration: time(2.5))

    let (from, to) = subRampVolumes(fullRange: full, fullFrom: 0.2, fullTo: 1.0, subRange: slice)

    #expect(approximatelyEqual(Double(from), 0.4))
    #expect(approximatelyEqual(Double(to), 0.6))
}

@Test("RenderPlanning: fitTransform aspect-fits and centers landscape media")
func renderPlanningFitTransformAspectFits() {
    let transform = fitTransform(
        naturalSize: CGSize(width: 1920, height: 1080),
        preferredTransform: .identity,
        into: CGSize(width: 1000, height: 1000))
    let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(transform)

    #expect(approximatelyEqual(rect.width, 1000))
    #expect(approximatelyEqual(rect.height, 562.5))
    #expect(approximatelyEqual(rect.minX, 0))
    #expect(approximatelyEqual(rect.minY, 218.75))
}

@Test("Time utilities: clamp invalid values and reject out-of-range captions")
func timeUtilitiesClampAndFormat() {
    #expect(TimeFormatting.timecode(.nan) == "0:00.00")
    #expect(TimeFormatting.timecode(-1) == "0:00.00")
    #expect(TimeFormatting.timecode(61.239) == "1:01.24")
    #expect(TimeFormatting.timecode(59.999) == "1:00.00")

    let maxCaptionTime = CMTime(seconds: 360_000, preferredTimescale: 1_000)
    #expect(CaptionImporter.parseTimestamp("100:00:00,000", separator: ",") == maxCaptionTime)
    #expect(CaptionImporter.parseTimestamp("100:00:01,000", separator: ",") == nil)
}

@Test("ProjectDocument: pure snapshot helpers preserve clip, transition, and media data")
func projectDocumentPureRoundTrip() throws {
    let mediaID = UUID()
    let trackID = UUID()
    let transition = TransitionDoc(type: TransitionType.wipe.rawValue,
                                   duration: CMTimeCode(time(1.25)),
                                   wipeAngle: 90)
    let document = ProjectDocument(
        name: "Package Round Trip",
        renderWidth: 3840,
        renderHeight: 2160,
        frameRate: 59.94,
        workingColourSpace: .displayP3,
        media: [
            MediaRef(id: mediaID,
                     displayName: "sample.mov",
                     bookmark: Data([1, 2, 3]),
                     duration: CMTimeCode(time(10)),
                     naturalWidth: 1920,
                     naturalHeight: 1080,
                     preferredTransform: TransformCode(.identity),
                     hasVideo: true,
                     hasAudio: true,
                     bundleRelativePath: "assets/sample.mov"),
        ],
        videoTracks: [
            TrackDoc(id: trackID,
                     name: "V1",
                     kind: "video",
                     isMuted: false,
                     clips: [
                        ClipDoc(mediaID: mediaID,
                                sourceStart: CMTimeCode(time(2)),
                                duration: CMTimeCode(time(3)),
                                timelineStart: CMTimeCode(time(5)),
                                opacity: 0.75,
                                effects: [.colourGrade(ColourGrade(exposure: 0.5,
                                                                    contrast: 1.1,
                                                                    saturation: 0.9,
                                                                    temperatureOffset: 100,
                                                                    tintOffset: -10))],
                                transition: transition),
                     ]),
        ],
        audioTracks: [],
        markers: [
            TimelineMarker(time: time(7), name: "Beat"),
        ],
        audioBus: AudioBusDoc(masterGain: 0.8,
                              trackInputs: [TrackInputDoc(trackID: trackID, pan: -0.25, gain: 1.2)]))

    let decoded = try ProjectDocument(data: document.encoded())

    #expect(decoded == document)
    #expect(decoded.videoTracks[0].clips[0].makeClip().transition?.type == .wipe)
    #expect(decoded.audioBus.trackInputs[0].trackInput.gain == 1.2)
}
