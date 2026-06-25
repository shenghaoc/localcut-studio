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

    @Test("DP beat track-back places beats near onset peaks")
    func dpBeatTrackSnapsToPeaks() {
        // Create an envelope with peaks at frames 10, 20, 30, 40 (every 10 frames).
        // With hopDuration 0.05, these are at 0.5, 1.0, 1.5, 2.0 seconds.
        // Tempo 120 BPM → interval 0.5s → grid aligns perfectly.
        var envelope = Array(repeating: Float(0), count: 60)
        for i in stride(from: 10, to: 60, by: 10) { envelope[i] = 1.0 }
        let peaks = [10, 20, 30, 40]

        let beats = BeatDetectionCore.dpBeatTrack(
            peaks: peaks, tempoBPM: 120, hopDuration: 0.05,
            envelope: envelope, durationSeconds: 2.5)

        // Beats should snap to the peak positions
        #expect(beats.count >= 4)
        let beatSeconds = beats.map(\.seconds)
        #expect(abs(beatSeconds[0] - 0.5) < 0.1)
        #expect(abs(beatSeconds[1] - 1.0) < 0.1)
        #expect(abs(beatSeconds[2] - 1.5) < 0.1)
        #expect(abs(beatSeconds[3] - 2.0) < 0.1)
    }

    private func writeFixtureWAV(sampleRate: Int, duration: Double, bpm: Double) throws -> URL {
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

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
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
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
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
}
