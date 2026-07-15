import Testing
import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore
@testable import LocalCut_Studio

// The pure detection-core unit tests (peak picking, tempo, quantisation,
// synthetic determinism, DP track-back, cache round-trip) live in
// `Packages/LocalCutCore/Tests/LocalCutCoreTests/BeatDetectionTests.swift` and
// run via the fast `swift test` loop. The app test target keeps the tests that
// genuinely need AVFoundation decode or the `EditorModel` integration.

@Suite("Beat tools — asset decode")
struct BeatAssetDecodeTests {

    @Test("Analysing the same WAV file fixture twice is deterministic")
    func deterministicFileAnalysis() async throws {
        let url = try writeFixtureWAV(sampleRate: 22_050, duration: 5, bpm: 120)
        defer { try? FileManager.default.removeItem(at: url) }
        let analyzer = BeatAnalyzer()

        let first = try await analyzer.analyze(url: url)
        let second = try await analyzer.analyze(url: url)

        #expect(first == second)
        #expect(!first.beatTimes.isEmpty)
        #expect(abs(first.tempoBPM - 120) < 5)
    }
}

// MARK: - WAV fixture helpers (shared by the decode + reopen tests)

func writeFixtureWAV(sampleRate: Int, duration: Double, bpm: Double) throws -> URL {
    let count = Int(Double(sampleRate) * duration)
    var samples = [Float](repeating: 0, count: count)
    let interval = 60.0 / bpm
    var t = 0.0
    while t < duration {
        let start = Int(t * Double(sampleRate))
        for offset in 0..<min(256, count - start) {
            let env = 1.0 - Float(offset) / 256.0
            samples[start + offset] = sin(Float(2 * Double.pi * 440 * Double(offset) / Double(sampleRate))) * env * 0.8
        }
        t += interval
    }

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("beat-fixture-\(UUID().uuidString).wav")
    let dataCount = samples.count * 2 // 16-bit PCM
    var header = Data(count: 44)
    header.replaceSubrange(0..<4, with: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    writeUInt32LE(&header, offset: 4, value: UInt32(36 + dataCount))
    header.replaceSubrange(8..<12, with: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    header.replaceSubrange(12..<16, with: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    writeUInt32LE(&header, offset: 16, value: 16) // chunk size
    header.replaceSubrange(20..<22, with: [0x01, 0x00]) // PCM
    header.replaceSubrange(22..<24, with: [0x01, 0x00]) // mono
    writeUInt32LE(&header, offset: 24, value: UInt32(sampleRate))
    writeUInt32LE(&header, offset: 28, value: UInt32(sampleRate * 2)) // byte rate
    header.replaceSubrange(32..<34, with: [0x02, 0x00]) // block align
    header.replaceSubrange(34..<36, with: [0x10, 0x00]) // 16 bits
    header.replaceSubrange(36..<40, with: [0x64, 0x61, 0x74, 0x61]) // "data"
    writeUInt32LE(&header, offset: 40, value: UInt32(dataCount))

    var wavData = header
    var pcm = Data(count: dataCount)
    for i in 0..<samples.count {
        let s16 = Int16(max(-32768, min(32767, samples[i] * 32767)))
        pcm[i * 2] = UInt8(truncatingIfNeeded: s16)
        pcm[i * 2 + 1] = UInt8(truncatingIfNeeded: s16 >> 8)
    }
    wavData.append(pcm)
    try wavData.write(to: tmpURL)
    return tmpURL
}

private func writeUInt32LE(_ data: inout Data, offset: Int, value: UInt32) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

@MainActor
@Suite("Beat tools — editor integration")
struct BeatToolsEditorTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func makeModel() -> (EditorModel, MediaItem, Clip, Clip) {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = time(8)
        media.hasVideo = true
        media.hasAudio = true
        model.project.mediaItems.append(media)

        let audioClip = Clip(mediaID: media.id, sourceStart: .zero, duration: time(5), timelineStart: .zero)
        model.project.audioTracks.first!.clips = [audioClip]

        let videoClip = Clip(mediaID: media.id, sourceStart: .zero, duration: time(5), timelineStart: .zero)
        model.project.videoTracks.first!.clips = [videoClip]

        model.beatAnalyses[media.id] = BeatAnalysis(
            tempoBPM: 120,
            beatTimes: [time(1), time(2), time(3), time(4)],
            confidence: 0.9)

        return (model, media, audioClip, videoClip)
    }

    private func makeBezierBeatCutFixture() -> (
        model: EditorModel,
        original: Clip,
        scalarTrack: Keyframed<Float>,
        speedTrack: Keyframed<Float>,
        transformTrack: Keyframed<Transform2D>
    ) {
        let model = EditorModel()
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = time(12)
        media.hasVideo = true
        media.hasAudio = true
        model.project.mediaItems = [media]

        let scalarTrack = Keyframed<Float>(
            keyframes: [
                Keyframe(
                    time: .zero,
                    value: 0.1,
                    outgoingHandle: KeyframeHandle(x: 0.25, y: 0.1)),
                Keyframe(
                    time: time(10),
                    value: 0.9,
                    incomingHandle: KeyframeHandle(x: 0.25, y: 0.1)),
            ],
            defaultValue: 0.1)
        let speedTrack = Keyframed<Float>(
            keyframes: [
                Keyframe(
                    time: .zero,
                    value: 1,
                    outgoingHandle: KeyframeHandle(x: 0.25, y: 1)),
                Keyframe(
                    time: time(10),
                    value: 3,
                    incomingHandle: KeyframeHandle(x: 0.25, y: 1)),
            ],
            defaultValue: 1)
        let transformTrack = Keyframed<Transform2D>(
            keyframes: [
                Keyframe(
                    time: .zero,
                    value: .identity,
                    outgoingHandle: KeyframeHandle(x: 0.25, y: 0)),
                Keyframe(
                    time: time(10),
                    value: Transform2D(
                        translateX: 0.8,
                        translateY: -0.4,
                        scale: 2,
                        rotation: 0.3),
                    incomingHandle: KeyframeHandle(x: 0.25, y: 0)),
            ],
            defaultValue: .identity)
        var skin = SkinSmoothEffect.neutral
        skin.strength = scalarTrack
        let sourceStart = time(2)
        let clip = Clip(
            mediaID: media.id,
            sourceStart: sourceStart,
            duration: time(10),
            timelineStart: time(1),
            geometry: ClipGeometry(
                positionOffset: CGSize(width: 0.2, height: -0.1),
                scale: 1.4,
                mask: .roundedRect),
            effects: [
                .skinSmooth(skin),
                .grain(GrainEffect(amount: scalarTrack)),
                .halation(HalationEffect(strength: scalarTrack)),
                .vignette(VignetteEffect(amount: scalarTrack)),
            ],
            transformKeyframes: transformTrack,
            speedCurve: speedTrack)
        model.project.videoTracks[0].clips = [clip]
        model.project.audioTracks[0].clips = []
        model.selectedClipID = clip.id
        model.beatAnalyses[media.id] = BeatAnalysis(
            tempoBPM: 120,
            beatTimes: [sourceStart + time(3), sourceStart + time(7)],
            confidence: 1)
        return (model, clip, scalarTrack, speedTrack, transformTrack)
    }

    @Test("Beat projection uses source-relative times plus global offset")
    func projectedBeatsUseClipMappingAndOffset() {
        let (model, _, _, _) = makeModel()
        model.beatOffsetSeconds = 0.05

        let times = model.projectedBeatTimes()

        #expect(times.map(\.seconds) == [1.05, 2.05, 3.05, 4.05])
    }

    @Test("Beat projection maps source beats through clip speed ramps")
    func projectedBeatsUseRetimedClipMapping() {
        let (model, _, _, videoClip) = makeModel()
        model.project.audioTracks.first!.clips = []
        model.project.videoTracks.first!.clips[0].speedCurve.defaultValue = 0.5

        let times = model.projectedBeatTimes()

        #expect(times.map(\.seconds) == [2, 4, 6, 8])
        #expect(model.project.videoTracks.first!.clips[0].id == videoClip.id)
    }

    @Test("Changing the beat offset re-projects beats (memo is invalidated)")
    func offsetChangeReprojectsBeats() {
        let (model, _, _, _) = makeModel()

        model.beatOffsetSeconds = 0.05
        #expect(model.projectedBeatTimes().map(\.seconds) == [1.05, 2.05, 3.05, 4.05])

        // Without cache invalidation this second read returns the stale 0.05 set.
        model.beatOffsetSeconds = 0.10
        #expect(model.projectedBeatTimes().map(\.seconds) == [1.10, 2.10, 3.10, 4.10])
    }

    @Test("Beats appear after analysis arrives even if the memo was seeded empty")
    func analysisArrivalReprojectsBeats() {
        let (model, media, _, _) = makeModel()
        let analysis = model.beatAnalyses[media.id]!

        // Seed the memo while no analysis exists (mirrors the inspector reading
        // canAlignSelectedClipToBeat before the user runs analysis).
        model.beatAnalyses.removeAll()
        #expect(model.projectedBeatTimes().isEmpty)

        // Analysis arriving must invalidate the memo so markers/Align light up.
        model.beatAnalyses[media.id] = analysis
        #expect(!model.projectedBeatTimes().isEmpty)
    }

    @Test("Moving a clip re-projects its beats after scheduleRebuild")
    func clipGeometryChangeReprojectsBeats() {
        let (model, _, _, _) = makeModel()
        model.project.videoTracks.first!.clips = [] // isolate to the audio clip

        #expect(model.projectedBeatTimes().map(\.seconds) == [1, 2, 3, 4])

        model.project.audioTracks.first!.clips[0].timelineStart = time(2)
        model.scheduleRebuild() // the chokepoint that drops the projected-beat memo

        #expect(model.projectedBeatTimes().map(\.seconds) == [3, 4, 5, 6])
    }

    @Test("Snap targets include projected beats only when the beat snap toggle is on")
    func snapTargetsIncludeBeatsWhenEnabled() {
        let (model, _, _, videoClip) = makeModel()

        #expect(!model.snapTargets(excluding: videoClip.id).contains(time(2)))
        model.snapToBeats = true
        #expect(model.snapTargets(excluding: videoClip.id).contains(time(2)))
    }

    @Test("resolveSnap (the actual drag path) snaps to beats when the toggle is on")
    func resolveSnapUsesBeatTargets() {
        let (model, _, _, videoClip) = makeModel()
        let candidate = time(1.97) // 0.03 s from beat 2.0, inside the 0.1 s threshold

        #expect(model.resolveSnap(candidate: candidate, excluding: videoClip.id) == candidate)
        model.snapToBeats = true
        #expect(model.resolveSnap(candidate: candidate, excluding: videoClip.id) == time(2))
    }

    @Test("Cut at beats splits the selected clip in one undoable edit")
    func cutAtBeatsUndo() {
        let (model, _, _, videoClip) = makeModel()
        model.selectedClipID = videoClip.id

        model.cutSelectedClipAtBeats()

        #expect(model.project.videoTracks.first!.clips.count == 5)
        #expect(model.canUndo)

        model.undo()
        #expect(model.project.videoTracks.first!.clips.count == 1)
        #expect(model.project.videoTracks.first!.clips[0].duration == time(5))
    }

    @Test("Cut at beats never produces sub-frame clips from densely spaced beats")
    func cutAtBeatsEnforcesMinFrameGap() {
        let model = EditorModel()
        model.project.frameRate = 30
        let media = MediaItem(url: URL(filePath: "/dev/null"))
        media.duration = time(8)
        media.hasAudio = true
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let clip = Clip(mediaID: media.id, sourceStart: .zero, duration: time(2), timelineStart: .zero)
        model.project.videoTracks.first!.clips = [clip]
        model.selectedClipID = clip.id
        // Beats every 5 ms — far below one frame (1/30 s) — would yield sub-frame
        // clips without the consecutive min-gap filter.
        let dense = stride(from: 0.2, through: 1.8, by: 0.005).map { time($0) }
        model.beatAnalyses[media.id] = BeatAnalysis(tempoBPM: 200, beatTimes: dense, confidence: 0.9)

        model.cutSelectedClipAtBeats()

        let oneFrame = CMTime(value: 1, timescale: CMTimeScale(model.project.frameRate))
        let clips = model.project.videoTracks.first!.clips
        #expect(clips.count > 1) // it did cut
        #expect(clips.allSatisfy { $0.duration >= oneFrame })
    }

    @Test("Cut at beats does not create an undo step when every beat is outside valid cut bounds")
    func cutAtBeatsRejectsNoOp() {
        let (model, media, _, videoClip) = makeModel()
        model.project.audioTracks.first!.clips = []
        model.selectedClipID = videoClip.id
        model.beatAnalyses[media.id] = BeatAnalysis(
            tempoBPM: 120,
            beatTimes: [.zero, videoClip.duration],
            confidence: 1)

        model.cutSelectedClipAtBeats()

        #expect(model.project.videoTracks.first!.clips == [videoClip])
        #expect(!model.canUndo)
        #expect(model.statusMessage == "No analysed beats fall inside the selected clip.")
    }

    @Test("Cut at beats preserves retime fields and slices in source time")
    func cutAtBeatsPreservesRetimedPieces() {
        let (model, _, _, videoClip) = makeModel()
        model.project.audioTracks.first!.clips = []
        model.project.videoTracks.first!.clips[0].speedCurve.defaultValue = 0.5
        model.project.videoTracks.first!.clips[0].preservePitch = false
        model.project.videoTracks.first!.clips[0].pitchAlgorithm = .spectral
        model.selectedClipID = videoClip.id

        model.cutSelectedClipAtBeats()

        let clips = model.project.videoTracks.first!.clips
        #expect(clips.count == 5)
        #expect(clips.map(\.timelineStart) == [time(0), time(2), time(4), time(6), time(8)])
        #expect(clips.map(\.duration) == [time(1), time(1), time(1), time(1), time(1)])
        #expect(clips.allSatisfy { $0.speedCurve.defaultValue == 0.5 })
        #expect(clips.allSatisfy { !$0.preservePitch })
        #expect(clips.allSatisfy { $0.pitchAlgorithm == .spectral })
        #expect(clips.allSatisfy { $0.outputDuration == time(2) })
    }

    @Test("Cut at beats preserves and rebases every scalar Bezier track")
    func cutAtBeatsPreservesScalarBezierTracks() throws {
        let fixture = makeBezierBeatCutFixture()

        fixture.model.cutSelectedClipAtBeats()

        let pieces = fixture.model.project.videoTracks[0].clips
            .sorted { $0.timelineStart < $1.timelineStart }
        #expect(pieces.count == 3)
        for piece in pieces {
            let sourceOffset = piece.sourceStart - fixture.original.sourceStart
            let sample = time(1)
            #expect(abs(
                piece.speedCurve.bezierValue(at: sample)
                    - fixture.speedTrack.bezierValue(at: sourceOffset + sample)) < 0.002)
            #expect(piece.speedCurve.keyframes.allSatisfy { $0.time <= piece.duration })

            let pieceTracks = piece.effects.compactMap(sourceLocalTrack)
            #expect(pieceTracks.count == 4)
            for track in pieceTracks {
                #expect(abs(
                    track.bezierValue(at: sample)
                        - fixture.scalarTrack.bezierValue(at: sourceOffset + sample)) < 0.002)
                #expect(track.keyframes.allSatisfy { $0.time <= piece.duration })
            }
        }
    }

    @Test("Cut at beats preserves and rebases transform curves and static geometry")
    func cutAtBeatsPreservesTransformBezierTracks() throws {
        let fixture = makeBezierBeatCutFixture()

        fixture.model.cutSelectedClipAtBeats()

        let pieces = fixture.model.project.videoTracks[0].clips
            .sorted { $0.timelineStart < $1.timelineStart }
        #expect(pieces.count == 3)
        for piece in pieces {
            let sourceOffset = piece.sourceStart - fixture.original.sourceStart
            let sample = time(1)
            let actual = piece.transformKeyframes.bezierValue(at: sample)
            let expected = fixture.transformTrack.bezierValue(at: sourceOffset + sample)
            #expect(abs(actual.tx - expected.tx) < 0.002)
            #expect(abs(actual.ty - expected.ty) < 0.002)
            #expect(abs(actual.decomposedScale - expected.decomposedScale) < 0.002)
            #expect(abs(actual.decomposedRotation - expected.decomposedRotation) < 0.002)
            #expect(piece.transformKeyframes.keyframes.allSatisfy { $0.time <= piece.duration })
            #expect(piece.geometry == fixture.original.geometry)
        }
    }

    @Test("Align to beat moves the selected clip to the nearest projected beat")
    func alignToBeat() throws {
        let (model, media, _, _) = makeModel()
        let targetClip = Clip(mediaID: media.id, sourceStart: .zero, duration: time(1), timelineStart: time(2.08))
        model.project.videoTracks.first!.clips = [targetClip]
        model.selectedClipID = targetClip.id
        model.beatAlignWindowSeconds = 0.2

        model.alignSelectedClipToBeat()

        let moved = try #require(model.project.videoTracks.first!.clips.first)
        #expect(moved.timelineStart == time(2))
    }

    @Test("Align refuses (no move) when the nearest beat slot is blocked by another clip")
    func alignRejectsBlockedBeat() throws {
        let (model, media, _, _) = makeModel()
        // Blocker occupies the beat-2 slot; the mover sits just off beat 2.
        let blocker = Clip(mediaID: media.id, sourceStart: .zero, duration: time(2), timelineStart: time(1.5))
        let mover = Clip(mediaID: media.id, sourceStart: .zero, duration: time(1), timelineStart: time(2.08))
        model.project.videoTracks.first!.clips = [blocker, mover]
        model.selectedClipID = mover.id
        model.beatAlignWindowSeconds = 0.2

        model.alignSelectedClipToBeat()

        let moverNow = try #require(model.project.videoTracks.first!.clips.first { $0.id == mover.id })
        #expect(moverNow.timelineStart == time(2.08)) // unchanged
        #expect(model.statusMessage.contains("blocked"))
        #expect(!model.canUndo) // nothing was mutated
    }

    @Test("Bundle cache persistence writes beat blobs under Caches/beats")
    func bundleCachePersistence() throws {
        let (model, media, _, _) = makeModel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beat-bundle-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = directory.appendingPathComponent("Project.lcbundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "abc123"
        model.beatAnalysisKeys[media.id] = key

        model.persistBeatCachesSynchronously(to: bundleURL)

        let cacheURL = bundleURL
            .appendingPathComponent(ProjectBundleLayout.beatCachesSubdirectory, isDirectory: true)
            .appendingPathComponent(BeatAnalysisCache.fileName(for: key))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("Full smoke: analyse → cut → undo → bundle save → cache reload")
    func fullSmokeTest() async throws {
        let (model, media, _, videoClip) = makeModel()
        model.selectedClipID = videoClip.id

        // 1. Verify beat analysis exists
        let analysis = try #require(model.beatAnalyses[media.id])
        #expect(analysis.beatTimes.count == 4)

        // 2. Cut at beats
        model.cutSelectedClipAtBeats()
        #expect(model.project.videoTracks.first!.clips.count == 5)

        // 3. Undo
        model.undo()
        #expect(model.project.videoTracks.first!.clips.count == 1)

        // 4. Bundle save with beat caches
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beat-smoke-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = directory.appendingPathComponent("Smoke.lcbundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.beatAnalysisKeys[media.id] = "smoke-key"
        model.persistBeatCachesSynchronously(to: bundleURL)

        // 5. Verify cache file exists and can be reloaded
        let cacheDir = bundleURL
            .appendingPathComponent(ProjectBundleLayout.beatCachesSubdirectory, isDirectory: true)
        let reloaded = try BeatAnalysisCache.read(key: "smoke-key", in: cacheDir)
        let reloadedAnalysis = try #require(reloaded)
        #expect(reloadedAnalysis == analysis)

        // 6. Verify beat markers can be projected after reload
        model.beatAnalyses.removeAll()
        model.beatAnalyses[media.id] = reloadedAnalysis
        let markers = model.projectedBeatMarkers()
        #expect(!markers.isEmpty)
    }

    @Test("Reopen: a fresh document reloads persisted beat caches via loadAvailableBeatCaches")
    func reopenReloadsBeatCachesAndMarkers() async throws {
        // A real WAV so the SHA-256 cache key matches across save and reopen.
        let wav = try writeFixtureWAV(sampleRate: 22_050, duration: 4, bpm: 120)
        defer { try? FileManager.default.removeItem(at: wav) }
        let key = try Fingerprint.sha256(of: wav)
        let analysis = try await BeatAnalyzer().analyze(url: wav)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beat-reopen-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = directory.appendingPathComponent("Reopen.lcbundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Save side: a project with the analysed source, caches persisted into the bundle.
        let saver = EditorModel()
        let savedMedia = MediaItem(url: wav)
        savedMedia.hasAudio = true
        savedMedia.duration = time(4)
        saver.project.mediaItems.append(savedMedia)
        saver.project.audioTracks.first!.clips = [
            Clip(mediaID: savedMedia.id, sourceStart: .zero, duration: time(4), timelineStart: .zero)
        ]
        saver.beatAnalyses[savedMedia.id] = analysis
        saver.beatAnalysisKeys[savedMedia.id] = key
        saver.persistBeatCachesSynchronously(to: bundleURL)

        // Reopen side: a fresh model pointed at the bundle reloads via the real entry point.
        // Production open sets projectStorageKind from ProjectLocationInspector; this
        // partial fixture mirrors that session state so beat caches resolve under the bundle.
        let reopened = EditorModel()
        reopened.documentURL = bundleURL
        reopened.projectStorageKind = .bundle
        let reopenedMedia = MediaItem(url: wav)
        reopenedMedia.hasAudio = true
        reopenedMedia.duration = time(4)
        reopened.project.mediaItems.append(reopenedMedia)
        reopened.project.audioTracks.first!.clips = [
            Clip(mediaID: reopenedMedia.id, sourceStart: .zero, duration: time(4), timelineStart: .zero)
        ]

        reopened.loadAvailableBeatCaches()
        await reopened.beatAnalysisTask?.value

        let reloaded = try #require(reopened.beatAnalyses[reopenedMedia.id])
        #expect(reloaded == analysis)
        #expect(reopened.showBeatMarkers)
        #expect(!reopened.projectedBeatMarkers().isEmpty)
    }

    private func sourceLocalTrack(_ effect: Effect) -> Keyframed<Float>? {
        switch effect {
        case .skinSmooth(let smooth): smooth.strength
        case .grain, .halation, .vignette: effect.lookStrength
        case .colourGrade, .lut: nil
        }
    }
}
