import Testing
import Foundation
import AVFoundation
import LocalCutCore
@testable import LocalCut_Studio

@Suite("Beat tools — detection core")
struct BeatDetectionCoreTests {

    @Test("Adaptive peak picker finds local onsets above the running median")
    func peakPicker() {
        let envelope: [Float] = [0, 0.02, 0.1, 0.9, 0.12, 0.03, 0.02, 0.2, 0.95, 0.18, 0.04]

        let peaks = BeatDetectionCore.pickOnsetPeaks(envelope, medianRadius: 2, delta: 0.2, minDistance: 2)

        #expect(peaks == [3, 8])
    }

    @Test("Autocorrelation tempo estimate recovers a regular 120 BPM envelope")
    func tempoEstimate() {
        var envelope = Array(repeating: Float(0), count: 80)
        for index in stride(from: 0, to: envelope.count, by: 10) {
            envelope[index] = 1
        }

        let bpm = BeatDetectionCore.estimateTempoBPM(envelope: envelope, hopDuration: 0.05)

        #expect(abs(bpm - 120) < 0.1)
    }

    @Test("Beat times quantise onto the project CMTime timescale")
    func quantisation() {
        let time = BeatDetectionCore.quantizedTime(seconds: 1.0 / 3.0)

        #expect(time.timescale == 600)
        #expect(time.value == 200)
    }

    @Test("Analysing the same synthetic fixture twice is deterministic")
    func deterministicSyntheticAnalysis() async throws {
        let samples = pulseTrain(sampleRate: 22_050, duration: 6, interval: 0.5)
        let analyzer = BeatAnalyzer()

        let first = try await analyzer.analyze(samples: samples, sampleRate: 22_050)
        let second = try await analyzer.analyze(samples: samples, sampleRate: 22_050)

        #expect(first == second)
        #expect(!first.beatTimes.isEmpty)
    }

    @Test("Versioned cache header round-trips beat analysis")
    func cacheRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("beat-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = BeatAnalysis(
            tempoBPM: 120,
            beatTimes: [
                CMTime(seconds: 0.5, preferredTimescale: 600),
                CMTime(seconds: 1.0, preferredTimescale: 600)
            ],
            confidence: 0.75)

        try BeatAnalysisCache.write(analysis, key: "abc123", in: directory)
        let restoredOptional = try BeatAnalysisCache.read(key: "abc123", in: directory)
        let restored = try #require(restoredOptional)

        #expect(restored == analysis)
    }

    private func pulseTrain(sampleRate: Int, duration: Double, interval: Double) -> [Float] {
        let count = Int(Double(sampleRate) * duration)
        var samples = Array(repeating: Float(0), count: count)
        var time = 0.0
        while time < duration {
            let start = Int(time * Double(sampleRate))
            for offset in 0..<min(128, count - start) {
                samples[start + offset] = 1
            }
            time += interval
        }
        return samples
    }
}

@MainActor
@Suite("Beat tools — editor integration")
struct BeatToolsEditorTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func makeModel() -> (EditorModel, MediaItem, Clip, Clip) {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
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

    @Test("Beat projection uses source-relative times plus global offset")
    func projectedBeatsUseClipMappingAndOffset() {
        let (model, _, _, _) = makeModel()
        model.beatOffsetSeconds = 0.05

        let times = model.projectedBeatTimes()

        #expect(times.map(\.seconds) == [1.05, 2.05, 3.05, 4.05])
    }

    @Test("Snap targets include projected beats only when the beat snap toggle is on")
    func snapTargetsIncludeBeatsWhenEnabled() {
        let (model, _, _, videoClip) = makeModel()

        #expect(!model.snapTargets(excluding: videoClip.id).contains(time(2)))
        model.snapToBeats = true
        #expect(model.snapTargets(excluding: videoClip.id).contains(time(2)))
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

    @Test("Bundle cache persistence writes beat blobs under Caches/beats")
    func bundleCachePersistence() throws {
        let (model, media, _, _) = makeModel()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
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
}
