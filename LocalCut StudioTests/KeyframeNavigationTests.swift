import Testing
import AVFoundation
import LocalCutCore
@testable import LocalCut_Studio

@MainActor
@Suite("Keyframe navigation availability")
struct KeyframeNavigationAvailabilityTests {
    @Test("Speed navigation availability matches seek tolerance")
    func speedNavigationAvailabilityMatchesSeekTolerance() {
        let model = makeModel { clip in
            clip.speedCurve = navigationTrack
        }

        verifyHalfFrameTolerance(
            in: model,
            hasPrevious: { model.hasPreviousSelectedClipSpeedKeyframe },
            hasNext: { model.hasNextSelectedClipSpeedKeyframe },
            seekPrevious: { model.seekToPreviousSelectedClipSpeedKeyframe() },
            seekNext: { model.seekToNextSelectedClipSpeedKeyframe() }
        )
    }

    @Test("Look navigation availability matches seek tolerance")
    func lookNavigationAvailabilityMatchesSeekTolerance() {
        let model = makeModel { clip in
            clip.effects = [.grain(GrainEffect(amount: navigationTrack))]
        }

        verifyHalfFrameTolerance(
            in: model,
            hasPrevious: { model.hasPreviousLookStrengthKeyframe(.grain) },
            hasNext: { model.hasNextLookStrengthKeyframe(.grain) },
            seekPrevious: { model.seekToPreviousLookStrengthKeyframe(.grain) },
            seekNext: { model.seekToNextLookStrengthKeyframe(.grain) }
        )
    }

    @Test("Look playhead strength is finite and effect-bounded")
    func lookPlayheadStrengthIsSanitized() {
        let invalidTrack = Keyframed<Float>(
            keyframes: [
                Keyframe(
                    time: time(0),
                    value: 0.2,
                    outgoingHandle: KeyframeHandle(x: 0.25, y: .nan)),
                Keyframe(time: time(2), value: 0.8),
            ],
            defaultValue: .nan)
        let model = makeModel { clip in
            var grain = GrainEffect()
            grain.amount = invalidTrack
            clip.effects = [.grain(grain)]
        }

        model.currentTime = 1
        #expect(model.lookStrengthAtPlayhead(.grain) == 0)

        model.currentTime = 8
        #expect(model.lookStrengthAtPlayhead(.grain) == 0)
    }

    @Test("Skin-smoothing navigation availability matches seek tolerance")
    func skinSmoothNavigationAvailabilityMatchesSeekTolerance() {
        let model = makeModel { clip in
            var smooth = SkinSmoothEffect()
            smooth.strength = navigationTrack
            clip.effects = [.skinSmooth(smooth)]
        }

        verifyHalfFrameTolerance(
            in: model,
            hasPrevious: { model.hasPreviousSelectedClipSkinSmoothStrengthKeyframe },
            hasNext: { model.hasNextSelectedClipSkinSmoothStrengthKeyframe },
            seekPrevious: { model.seekToPreviousSelectedClipSkinSmoothStrengthKeyframe() },
            seekNext: { model.seekToNextSelectedClipSkinSmoothStrengthKeyframe() }
        )
    }

    @Test("Skin-smoothing UI strengths are finite and bounded")
    func skinSmoothUIStrengthsAreSanitized() {
        let model = makeModel { clip in
            var smooth = SkinSmoothEffect()
            smooth.strength.defaultValue = .nan
            clip.effects = [.skinSmooth(smooth)]
        }

        #expect(model.selectedClipSkinSmoothDefaultStrength == 0)
        model.currentTime = 1
        #expect(model.selectedClipSkinSmoothStrengthAtPlayhead == 0)
    }

    private var navigationTrack: Keyframed<Float> {
        Keyframed(
            keyframes: [
                Keyframe(time: time(1), value: 1),
                Keyframe(time: time(3), value: 1),
            ],
            defaultValue: 1
        )
    }

    private func makeModel(configure: (inout Clip) -> Void) -> EditorModel {
        let model = EditorModel()
        model.project.frameRate = 30
        var clip = Clip(
            mediaID: UUID(),
            sourceStart: .zero,
            duration: time(6),
            timelineStart: .zero
        )
        configure(&clip)
        model.project.videoTracks[0].clips = [clip]
        model.selectedClipID = clip.id
        model.totalDuration = clip.outputDuration.seconds
        return model
    }

    private func verifyHalfFrameTolerance(
        in model: EditorModel,
        hasPrevious: () -> Bool,
        hasNext: () -> Bool,
        seekPrevious: () -> Void,
        seekNext: () -> Void
    ) {
        let frameDuration = 1 / model.project.frameRate
        let insideTolerance = frameDuration * 0.25
        let outsideTolerance = frameDuration * 0.75

        model.currentTime = 1 + insideTolerance
        let nearFirstKeyframe = model.currentTime
        #expect(!hasPrevious())
        #expect(hasNext())
        seekPrevious()
        #expect(approximatelyEqual(model.currentTime, nearFirstKeyframe))

        model.currentTime = 3 - insideTolerance
        let nearLastKeyframe = model.currentTime
        #expect(hasPrevious())
        #expect(!hasNext())
        seekNext()
        #expect(approximatelyEqual(model.currentTime, nearLastKeyframe))

        model.currentTime = 1 + outsideTolerance
        #expect(hasPrevious())
        seekPrevious()
        #expect(approximatelyEqual(model.currentTime, 1))

        model.currentTime = 3 - outsideTolerance
        #expect(hasNext())
        seekNext()
        #expect(approximatelyEqual(model.currentTime, 3))
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-6
    }
}
