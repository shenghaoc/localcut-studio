import Testing
import Foundation
import AVFoundation
@testable import LocalCut_Studio

// Tests for feature-audio-master-bus (P16 infrastructure).
//
// Scope: parameter mutation routes through undo (R6.1), the offline graph
// renders without `setVoiceProcessingEnabled` (R6.3), a synthesised non-silent
// block lights up the meter snapshot (R6.2), `VolumeEnvelope` clamps fades
// against the clip duration (R6.4), and a default project's audio mix is
// bit-identical to the pre-bus path (R6.5).

private func cm(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

// MARK: - R6.1 — master gain mutation undoable

@MainActor
@Test("AudioMasterBus: setMasterGain mutation is undoable and restorable (R6.1)")
func masterGainIsUndoable() {
    let model = EditorModel()
    #expect(model.project.masterGain == 1)
    #expect(model.canUndo == false)

    model.setMasterGain(0.6)
    #expect(model.project.masterGain == 0.6)
    #expect(model.canUndo == true)

    model.undo()
    #expect(model.project.masterGain == 1)
}

@MainActor
@Test("AudioMasterBus: coalesced gain drags fold into a single undo step")
func masterGainCoalescesAcrossDrag() {
    let model = EditorModel()
    for step in stride(from: 0.95, through: 0.5, by: -0.05) {
        model.setMasterGain(Float(step), coalesced: true)
    }
    model.commitCoalescedUndo()
    #expect(model.canUndo == true)
    // One undo restores all the way back to the original (the coalesced
    // before-snapshot was captured at the start of the gesture).
    model.undo()
    #expect(abs(model.project.masterGain - 1) < 1e-6)
}

@MainActor
@Test("AudioMasterBus: setTrackInput routes through undo")
func trackInputIsUndoable() {
    let model = EditorModel()
    let trackID = model.project.audioTracks[0].id
    model.setTrackInput(TrackInput(id: trackID, pan: -0.5, gain: 0.8))
    #expect(model.project.trackInputs.count == 1)
    #expect(model.project.trackInputs[0].pan == -0.5)
    model.undo()
    #expect(model.project.trackInputs.isEmpty)
}

@MainActor
@Test("AudioMasterBus: setClipVolumeEnvelope routes through undo")
func clipEnvelopeIsUndoable() {
    let model = EditorModel()
    let clip = Clip(mediaID: UUID(), sourceStart: .zero,
                    duration: cm(5), timelineStart: .zero)
    model.project.audioTracks[0].clips = [clip]

    let envelope = VolumeEnvelope(fadeIn: cm(0.5), fadeOut: cm(0.5))
    model.setClipVolumeEnvelope(envelope, clipID: clip.id)
    #expect(model.project.audioTracks[0].clips[0].volumeEnvelope.fadeIn == cm(0.5))
    model.undo()
    #expect(model.project.audioTracks[0].clips[0].volumeEnvelope.isEmpty)
}

// MARK: - R6.4 — VolumeEnvelope clamping

@Test("VolumeEnvelope: fadeIn + fadeOut greater than clip duration each clamp to half (R6.4)")
func envelopeFadesClampWhenSumExceedsDuration() {
    let envelope = VolumeEnvelope(fadeIn: cm(4), fadeOut: cm(4))
    let (fi, fo) = envelope.clampedFades(clipDuration: cm(2))
    #expect(abs(fi.seconds - 1) < 1e-6)
    #expect(abs(fo.seconds - 1) < 1e-6)
}

@Test("VolumeEnvelope: each fade individually clamps to clip duration")
func envelopeSingleFadeClampsToDuration() {
    let envelope = VolumeEnvelope(fadeIn: cm(10), fadeOut: .zero)
    let (fi, fo) = envelope.clampedFades(clipDuration: cm(3))
    #expect(abs(fi.seconds - 3) < 1e-6)
    #expect(fo == .zero)
}

@Test("VolumeEnvelope: fades that already fit are untouched")
func envelopeFadesNoClampWhenSumFits() {
    let envelope = VolumeEnvelope(fadeIn: cm(0.5), fadeOut: cm(0.5))
    let (fi, fo) = envelope.clampedFades(clipDuration: cm(5))
    #expect(abs(fi.seconds - 0.5) < 1e-6)
    #expect(abs(fo.seconds - 0.5) < 1e-6)
}

@Test("VolumeEnvelope: a Ramp range past the clip end clamps to the clip range (R6.4)")
func envelopeRampClampsToClipRange() {
    let clipRange = CMTimeRange(start: cm(0), duration: cm(2))
    let ramp = CMTimeRange(start: cm(1), duration: cm(5))   // ends at 6s, well past
    let clamped = VolumeEnvelope.clampedRange(ramp, to: clipRange)
    #expect(clamped != nil)
    #expect(abs((clamped!.end - clipRange.end).seconds) < 1e-6)
}

@Test("VolumeEnvelope: a Ramp entirely outside the clip range is dropped")
func envelopeRampOutsideDropped() {
    let clipRange = CMTimeRange(start: cm(0), duration: cm(2))
    let ramp = CMTimeRange(start: cm(5), duration: cm(1))
    #expect(VolumeEnvelope.clampedRange(ramp, to: clipRange) == nil)
}

@Test("VolumeEnvelope: zero clip duration produces zero fades")
func envelopeFadesZeroClipDuration() {
    let envelope = VolumeEnvelope(fadeIn: cm(1), fadeOut: cm(1))
    let (fi, fo) = envelope.clampedFades(clipDuration: .zero)
    #expect(fi == .zero)
    #expect(fo == .zero)
}

// MARK: - R6.3 + R6.2 — offline graph + meter snapshot

@MainActor
@Test("AudioMasterBus: offline graph prepares without setVoiceProcessingEnabled (R6.3)")
func offlineGraphBuildsWithoutVoiceProcessing() throws {
    let bus = AudioMasterBus()
    try bus.prepareOffline()
    #expect(bus.isOfflineRunning == true)
    bus.teardownOffline()
    #expect(bus.isOfflineRunning == false)
}

@MainActor
@Test("AudioMasterBus: meter snapshot lights up after a non-silent offline render (R6.2)")
func meterSnapshotUpdatesAfterRender() throws {
    let bus = AudioMasterBus()
    let format = AudioMasterBus.canonicalFormat
    try bus.prepareOffline(format: format, maximumFrameCount: 4096)
    defer { bus.teardownOffline() }

    // Synthesise one second of a half-amplitude sine wave so the meter has
    // an unambiguous signal to read.
    let frameCount: AVAudioFrameCount = 4096
    guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        Issue.record("could not allocate source buffer")
        return
    }
    source.frameLength = frameCount
    if let channels = source.floatChannelData {
        let channelCount = Int(format.channelCount)
        let twoPi: Float = 2 * .pi
        let freq: Float = 440
        let sampleRate = Float(format.sampleRate)
        for c in 0..<channelCount {
            for i in 0..<Int(frameCount) {
                channels[c][i] = 0.5 * sinf(twoPi * freq * Float(i) / sampleRate)
            }
        }
    }
    bus.scheduleOfflineBuffer(source)

    guard let render = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        Issue.record("could not allocate render buffer")
        return
    }
    let status = try bus.renderOfflineBlock(into: render)
    #expect(status == .success)
    // Manual rendering pulls the tap synchronously; after the call returns
    // the snapshot should reflect the rendered block.
    let snapshot = bus.meterSnapshot
    #expect(snapshot.peakLeft > 0)
    #expect(snapshot.rmsLeft > 0)
}

@Test("AudioMasterBus.computeMeter: silent buffer ⇒ zero peak/rms")
func computeMeterOnSilence() {
    let format = AudioMasterBus.canonicalFormat
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    buf.frameLength = 1024
    // Default-allocated channelData is zero, so this is genuine silence.
    let snapshot = AudioMasterBus.computeMeter(buffer: buf)
    #expect(snapshot.peakLeft == 0)
    #expect(snapshot.peakRight == 0)
    #expect(snapshot.rmsLeft == 0)
    #expect(snapshot.rmsRight == 0)
}

@Test("AudioMasterBus.computeMeter: full-amplitude DC ⇒ peak = 1, rms = 1")
func computeMeterOnUnitDC() {
    let format = AudioMasterBus.canonicalFormat
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    buf.frameLength = 512
    if let ch = buf.floatChannelData {
        for c in 0..<Int(format.channelCount) {
            for i in 0..<512 { ch[c][i] = 1 }
        }
    }
    let snapshot = AudioMasterBus.computeMeter(buffer: buf)
    #expect(abs(snapshot.peakLeft - 1) < 1e-6)
    #expect(abs(snapshot.rmsLeft - 1) < 1e-6)
}

// MARK: - R6.5 — regression guard: defaults are bit-identical

@MainActor
@Suite("Audio bus: default-project regression (R6.5)")
struct AudioBusRegressionTests {

    @Test("CompositionBuilder: default project (no bus contribution) leaves the audio mix nil when there is no crossfade")
    func defaultProjectNoMixWhenNoCrossfade() async throws {
        let project = Project()
        let url = try makeAudioFixture(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let media = try await loadAudioMedia(from: url)
        project.mediaItems.append(media)
        project.audioTracks[0].clips = [
            Clip(mediaID: media.id, sourceStart: .zero, duration: cm(1), timelineStart: .zero)
        ]
        let built = try #require(try await CompositionBuilder.build(project: project))
        #expect(built.audioMix == nil)
    }

    @Test("CompositionBuilder: changing master gain makes the audio mix appear even without a crossfade")
    func busGainTriggersAudioMix() async throws {
        let project = Project()
        let url = try makeAudioFixture(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let media = try await loadAudioMedia(from: url)
        project.mediaItems.append(media)
        project.audioTracks[0].clips = [
            Clip(mediaID: media.id, sourceStart: .zero, duration: cm(1), timelineStart: .zero)
        ]
        project.masterGain = 0.5
        let built = try #require(try await CompositionBuilder.build(project: project))
        let mix = try #require(built.audioMix)
        // Exactly one input piece on the audio track ⇒ one set of input params.
        #expect(mix.inputParameters.count == 1)
    }

    @Test("AudioBusDoc: legacy document (no audioBus key) decodes to defaults")
    func legacyDocumentMissingAudioBusDecodesToDefaults() throws {
        let json = """
        {
          "name": "Legacy",
          "schemaVersion": 2,
          "renderWidth": 1920, "renderHeight": 1080, "frameRate": 30,
          "media": [], "videoTracks": [], "audioTracks": [], "captionTracks": []
        }
        """
        let doc = try ProjectDocument(data: Data(json.utf8))
        #expect(doc.audioBus.masterGain == 1)
        #expect(doc.audioBus.trackInputs.isEmpty)
    }

    @Test("ProjectDocument: schema is v3 once the audio master bus ships")
    func schemaVersionAdvancesToV3() {
        #expect(ProjectDocument.currentSchemaVersion >= 3)
    }

    @Test("ProjectDocument: audio bus + clip envelopes round-trip losslessly")
    func audioBusRoundTrips() throws {
        let project = Project()
        let trackID = project.audioTracks[0].id
        project.masterGain = 0.75
        project.trackInputs = [TrackInput(id: trackID, pan: -0.3, gain: 1.4)]

        let clip = Clip(mediaID: UUID(), sourceStart: .zero,
                        duration: cm(3), timelineStart: .zero,
                        volumeEnvelope: VolumeEnvelope(
                            fadeIn: cm(0.4), fadeOut: cm(0.6),
                            ramps: [VolumeEnvelope.Ramp(
                                range: CMTimeRange(start: cm(1), duration: cm(0.5)),
                                fromVolume: 0.2, toVolume: 0.9)]))
        project.audioTracks[0].clips = [clip]

        let data = try ProjectDocument(project: project).encoded()
        let back = try ProjectDocument(data: data)
        #expect(abs(back.audioBus.masterGain - 0.75) < 1e-6)
        #expect(back.audioBus.trackInputs.count == 1)
        #expect(abs(back.audioBus.trackInputs[0].pan + 0.3) < 1e-6)
        #expect(abs(back.audioBus.trackInputs[0].gain - 1.4) < 1e-6)

        let restoredClip = back.audioTracks[0].clips[0]
        #expect(abs(restoredClip.volumeEnvelope.fadeIn.seconds - 0.4) < 1e-6)
        #expect(abs(restoredClip.volumeEnvelope.fadeOut.seconds - 0.6) < 1e-6)
        #expect(restoredClip.volumeEnvelope.ramps.count == 1)
        #expect(abs(restoredClip.volumeEnvelope.ramps[0].fromVolume - 0.2) < 1e-6)
        #expect(abs(restoredClip.volumeEnvelope.ramps[0].toVolume - 0.9) < 1e-6)
    }
}

// MARK: - Audio fixture helpers (used by the regression tests)

/// Writes a short CAF containing one mono PCM audio track and returns its
/// URL. Uses `AVAudioFile` so we don't have to plumb CoreMedia sample buffers
/// by hand. The composition builder accepts any container `AVAsset` can load.
@MainActor
private func makeAudioFixture(seconds: Double, sampleRate: Double = 48_000) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-bus-fixture-\(UUID().uuidString).caf")
    try? FileManager.default.removeItem(at: url)

    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: 1,
                                     interleaved: false) else {
        throw NSError(domain: "AudioBusTests", code: -1)
    }
    let file = try AVAudioFile(forWriting: url,
                               settings: format.settings,
                               commonFormat: format.commonFormat,
                               interleaved: format.isInterleaved)
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "AudioBusTests", code: -2)
    }
    buffer.frameLength = frameCount
    // Default-allocated channelData is zero ⇒ true silence; that's fine for
    // the regression tests, which only need a valid audio track to exist.
    try file.write(from: buffer)
    return url
}

@MainActor
private func loadAudioMedia(from url: URL) async throws -> MediaItem {
    let item = MediaItem(url: url)
    item.duration = try await item.asset.load(.duration)
    let audioTracks = try await item.asset.loadTracks(withMediaType: .audio)
    _ = try #require(audioTracks.first)
    item.hasAudio = true
    return item
}
