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
                     orderingStart: Double? = nil,
                     transitionStart: Double? = nil,
                     transitionEnd: Double? = nil,
                     type: TransitionType? = nil) -> VisibleSegment {
    VisibleSegment(compTrackID: id,
                   start: start,
                   orderingStart: orderingStart,
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

@Test("Look effects clamp authored and keyframed values")
func lookEffectsClampValues() {
    let incoming = KeyframeHandle(x: 0.2, y: 0.3)
    let outgoing = KeyframeHandle(x: 0.4, y: 0.5)
    var grain = GrainEffect(
        amount: Keyframed(keyframes: [
            Keyframe(time: time(1), value: 2,
                     incomingHandle: incoming,
                     outgoingHandle: outgoing),
        ], defaultValue: -1),
        size: 20)
    var halation = HalationEffect(
        strength: Keyframed(keyframes: [Keyframe(time: time(1), value: -1)], defaultValue: 2),
        threshold: 2,
        radius: 100,
        redBoost: 5)
    var vignette = VignetteEffect(
        amount: Keyframed(keyframes: [Keyframe(time: time(1), value: 2)], defaultValue: -2),
        radius: 0,
        softness: 2)

    grain.clamp()
    halation.clamp()
    vignette.clamp()

    #expect(grain.amount.defaultValue == 0)
    #expect(grain.amount.keyframes[0].value == 1)
    #expect(grain.amount.keyframes[0].incomingHandle == incoming)
    #expect(grain.amount.keyframes[0].outgoingHandle == outgoing)
    #expect(grain.size == 8)
    #expect(halation.strength.defaultValue == 1)
    #expect(halation.strength.keyframes[0].value == 0)
    #expect(halation.threshold == 1)
    #expect(halation.radius == 80)
    #expect(halation.redBoost == 2)
    #expect(vignette.amount.defaultValue == -1)
    #expect(vignette.amount.keyframes[0].value == 1)
    #expect(vignette.radius == 0.05)
    #expect(vignette.softness == 1)
}

@Test("Decoding look effect models clamps stored values")
func lookEffectDecodeClampsStoredValues() throws {
    let grain = try JSONDecoder().decode(GrainEffect.self, from: Data("""
    {
      "amount": { "keyframes": [], "defaultValue": 8 },
      "size": 99,
      "monochrome": true,
      "seed": 7
    }
    """.utf8))
    let halation = try JSONDecoder().decode(HalationEffect.self, from: Data("""
    {
      "strength": { "keyframes": [], "defaultValue": -2 },
      "threshold": -1,
      "radius": 999,
      "redBoost": 9
    }
    """.utf8))
    let vignette = try JSONDecoder().decode(VignetteEffect.self, from: Data("""
    {
      "amount": { "keyframes": [], "defaultValue": -8 },
      "radius": 0,
      "softness": 9
    }
    """.utf8))

    #expect(grain.amount.defaultValue == 1)
    #expect(grain.size == 8)
    #expect(halation.strength.defaultValue == 0)
    #expect(halation.threshold == 0)
    #expect(halation.radius == 80)
    #expect(halation.redBoost == 2)
    #expect(vignette.amount.defaultValue == -1)
    #expect(vignette.radius == 0.05)
    #expect(vignette.softness == 1)
}

@Test("LookPresetV1 round-trips ordered nodes and applies only look effects")
func lookPresetRoundTripAndApply() throws {
    let preset = LookPresetV1(
        name: "Round Trip",
        nodes: [
            .halation(HalationEffect(strength: Keyframed(defaultValue: 0.2))),
            .vignette(VignetteEffect(amount: Keyframed(defaultValue: 0.3))),
            .grain(GrainEffect(amount: Keyframed(defaultValue: 0.4))),
        ],
        lut: LookPresetLUTReference(relativePath: "luts/warm.cube", displayName: "warm.cube"))

    let decoded = try LookPresetV1(data: preset.encoded())
    #expect(decoded == preset)

    let base: [Effect] = [
        .colourGrade(.neutral),
        .skinSmooth(.neutral),
        .grain(.neutral),
    ]
    let applied = decoded.applying(to: base)
    #expect(applied.count == 5)
    #expect(applied.contains { if case .colourGrade = $0 { return true }; return false })
    #expect(applied.contains { if case .skinSmooth = $0 { return true }; return false })
    #expect(applied.filter(\.isLookEffect).count == 3)
}

@Test("Replacing individual look effects keeps canonical render order")
func replacingLookEffectsKeepsCanonicalOrder() {
    let chain: [Effect] = [.grain(GrainEffect(amount: Keyframed(defaultValue: 0.2)))]
    let updated = chain
        .replacingLookEffect(.halation(HalationEffect(strength: Keyframed(defaultValue: 0.2))))
        .replacingLookEffect(.vignette(VignetteEffect(amount: Keyframed(defaultValue: 0.2))))

    #expect(updated.compactMap(\.lookKind) == [.halation, .vignette, .grain])
}

@Test("canonicalPipelineOrder sorts effects into the fixed render order")
func canonicalPipelineOrderSorts() {
    let chain: [Effect] = [
        .grain(.neutral),
        .lut(bookmark: Data([0x01])),
        .vignette(.neutral),
        .colourGrade(.neutral),
        .halation(.neutral),
        .skinSmooth(.neutral),
    ]
    #expect(chain.canonicalPipelineOrder().map(\.pipelineOrder) == [0, 1, 2, 3, 4, 5])
}

@Test("Decoding a look preset clamps out-of-range node params")
func lookPresetDecodeClampsParams() throws {
    let json = """
    {
      "schemaVersion": 1,
      "name": "Out Of Range",
      "nodes": [
        {
          "effectName": "halation",
          "params": {
            "strength": { "keyframes": [], "defaultValue": 5 },
            "threshold": 9,
            "radius": 9999,
            "redBoost": 8
          }
        }
      ]
    }
    """
    let decoded = try LookPresetV1(data: Data(json.utf8))
    let halation = decoded.nodes.compactMap { node -> HalationEffect? in
        if case .halation(let h) = node { return h }
        return nil
    }.first
    #expect(halation?.strength.defaultValue == 1)
    #expect(halation?.threshold == 1)
    #expect(halation?.radius == 80)
    #expect(halation?.redBoost == 2)
}

@Test("Look strength accessor reads and replaces the keyframed parameter")
func lookStrengthAccessors() {
    let grain = Effect.grain(GrainEffect(amount: Keyframed(defaultValue: 0.3)))
    #expect(grain.lookStrength?.defaultValue == 0.3)

    var track = Keyframed<Float>(defaultValue: 0.1)
    track.addKeyframe(at: time(1), value: 0.9)
    let updated = grain.settingLookStrength(track)
    #expect(updated.lookStrength?.keyframes.count == 1)
    #expect(updated.lookStrength?.defaultValue == 0.1)

    let lut = Effect.lut(bookmark: Data([0x01]))
    #expect(lut.lookStrength == nil)
    #expect(lut.settingLookStrength(track) == lut)
}

@Test("Built-in look preset library has ten populated presets")
func builtInLookPresetLibraryPopulated() {
    #expect(LookPresetLibrary.builtInPresets.count >= 10)
    #expect(LookPresetLibrary.builtInPresets.allSatisfy { !$0.nodes.isEmpty })
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

@Test("RenderPlanning: retimed outgoing subsegments keep transition ordering")
func renderPlanningUsesOrderingStartForRetimedSubsegments() {
    let visible = [
        segment(track: 1, start: 4.6, orderingStart: 0),
        segment(track: 2, start: 4, transitionStart: 4, transitionEnd: 5, type: .crossDissolve),
    ]

    #expect(planUnits(visible: visible, midpoint: 4.75) == [
        .transition(outgoing: 1, incoming: 2, type: .crossDissolve, wipeAngle: 0),
    ])
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
    #expect(TimeFormatting.timecode(360_000) == "6000:00.00")
    #expect(TimeFormatting.timecode(360_000.01) == "0:00.00")
    #expect(TimeFormatting.timecode(1e17) == "0:00.00")

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

// MARK: - Chapter export tests (Phase 44)

@Test("YouTube chapter validator checks final span against project duration")
func youTubeChapterValidatorChecksFinalSpan() {
    let chapters = [
        YouTubeChapterLine(time: time(0), title: "Intro"),
        YouTubeChapterLine(time: time(12), title: "Demo"),
        YouTubeChapterLine(time: time(25), title: "Wrap"),
    ]

    let issues = YouTubeChapterValidator.validate(chapters, projectDuration: time(30))

    #expect(issues.contains(.spanTooShort(index: 2, duration: 5)))
}

@Test("Chapter merge repair removes the following boundary for a short span")
func chapterMergeRepairRemovesFollowingBoundary() {
    let shortBoundaryID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000002")!
    let markers = [
        TimelineMarker(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!,
                       time: time(0), name: "Intro", kind: .chapter),
        TimelineMarker(id: shortBoundaryID,
                       time: time(5), name: "Setup", kind: .chapter),
        TimelineMarker(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000003")!,
                       time: time(16), name: "Demo", kind: .chapter),
        TimelineMarker(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000004")!,
                       time: time(32), name: "Wrap", kind: .chapter),
    ]

    let repaired = YouTubeChapterValidator.repairedMarkers(
        from: markers,
        projectDuration: time(45),
        strategy: .merge)
    let chapters = YouTubeChapterValidator.chapters(from: repaired, projectDuration: time(45))

    #expect(!repaired.contains { $0.id == shortBoundaryID })
    #expect(chapters.map(\.title) == ["Intro", "Demo", "Wrap"])
    #expect(YouTubeChapterValidator.validate(chapters, projectDuration: time(45)).isEmpty)
}

@Test("Chapter drop repair removes the short chapter while preserving the zero marker")
func chapterDropRepairRemovesShortChapter() {
    let shortChapterID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000012")!
    let markers = [
        TimelineMarker(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000011")!,
                       time: time(0), name: "Intro", kind: .chapter),
        TimelineMarker(id: shortChapterID,
                       time: time(12), name: "Aside", kind: .chapter),
        TimelineMarker(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000013")!,
                       time: time(18), name: "Demo", kind: .chapter),
        TimelineMarker(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000014")!,
                       time: time(32), name: "Wrap", kind: .chapter),
    ]

    let repaired = YouTubeChapterValidator.repairedMarkers(
        from: markers,
        projectDuration: time(50),
        strategy: .drop)
    let chapters = YouTubeChapterValidator.chapters(from: repaired, projectDuration: time(50))

    #expect(!repaired.contains { $0.id == shortChapterID })
    #expect(chapters.map(\.title) == ["Intro", "Demo", "Wrap"])
    #expect(chapters.first?.time == time(0))
    #expect(YouTubeChapterValidator.validate(chapters, projectDuration: time(50)).isEmpty)
}

// MARK: - Overlay model tests (Phase 38b)

@Test("OverlayClip model round-trips through OverlayClipDoc")
func overlayClipDocRoundTrip() {
    let overlay = OverlayClip(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        sourceType: .animatedImage,
        timelineStart: time(2),
        duration: time(5),
        positionOffset: CGSize(width: 0.3, height: -0.1),
        scale: 1.5,
        rotation: 0.785,
        opacity: 0.8,
        endAction: .freeze)
    let doc = OverlayClipDoc(
        overlay: overlay,
        bookmark: Data([0xDE, 0xAD]))
    let restored = doc.makeOverlayClip()

    #expect(restored.id == overlay.id)
    #expect(restored.sourceType == .animatedImage)
    #expect(restored.timelineStart == overlay.timelineStart)
    #expect(restored.duration == overlay.duration)
    #expect(restored.positionOffset.width == overlay.positionOffset.width)
    #expect(restored.positionOffset.height == overlay.positionOffset.height)
    #expect(restored.scale == overlay.scale)
    #expect(restored.rotation == overlay.rotation)
    #expect(restored.opacity == overlay.opacity)
    #expect(restored.endAction == .freeze)
}

@Test("OverlayClipDoc clamps malformed transform values when restoring model")
func overlayClipDocClampsMalformedTransformValues() {
    let doc = OverlayClipDoc(
        sourceType: .animatedImage,
        bookmark: Data(),
        timelineStart: CMTimeCode(time(1)),
        duration: CMTimeCode(time(2)),
        scale: 0,
        opacity: -0.25,
        endAction: .loop)
    let restored = doc.makeOverlayClip()

    #expect(restored.scale == 0.1)
    #expect(restored.opacity == 0)

    let overOpaque = OverlayClipDoc(
        sourceType: .animatedImage,
        bookmark: Data(),
        timelineStart: CMTimeCode(time(1)),
        duration: CMTimeCode(time(2)),
        scale: 1,
        opacity: 1.25,
        endAction: .loop).makeOverlayClip()
    #expect(overOpaque.opacity == 1)
}

@Test("OverlayClipDoc round-trips through JSON encoding")
func overlayClipDocJSONRoundTrip() throws {
    let doc = OverlayClipDoc(
        sourceType: .lottie,
        bookmark: Data([0xCA, 0xFE]),
        timelineStart: CMTimeCode(time(1)),
        duration: CMTimeCode(time(3)),
        positionOffsetX: 0.5,
        positionOffsetY: -0.25,
        scale: 2.0,
        rotation: 1.57,
        opacity: 0.6,
        endAction: .hide)
    let encoded = try JSONEncoder().encode(doc)
    let decoded = try JSONDecoder().decode(OverlayClipDoc.self, from: encoded)

    #expect(decoded.sourceType == .lottie)
    #expect(decoded.timelineStart == doc.timelineStart)
    #expect(decoded.duration == doc.duration)
    #expect(decoded.positionOffsetX == 0.5)
    #expect(decoded.endAction == .hide)
}

@Test("OverlaySourceType display names are non-empty")
func overlaySourceTypeDisplayNames() {
    for type in OverlaySourceType.allCases {
        #expect(!type.displayName.isEmpty)
    }
}

@Test("OverlayEndAction display names are non-empty")
func overlayEndActionDisplayNames() {
    for action in OverlayEndAction.allCases {
        #expect(!action.displayName.isEmpty)
    }
}
