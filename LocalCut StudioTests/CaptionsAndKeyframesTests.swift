import Testing
import AVFoundation
import CoreGraphics
@testable import LocalCut_Studio

// MARK: - Keyframes (feature-keyframes V1–V4)

@Test("Keyframed<Float>: empty returns defaultValue at every time")
func keyframesEmptyReturnsDefault() {
    let k = Keyframed<Float>(defaultValue: 0.42)
    #expect(k.value(at: .zero) == 0.42)
    #expect(k.value(at: CMTime(seconds: 5, preferredTimescale: 600)) == 0.42)
    #expect(k.isAnimated == false)
}

@Test("Keyframed<Float>: single keyframe returns its value everywhere")
func keyframesSingle() {
    var k = Keyframed<Float>(defaultValue: 0)
    k.addKeyframe(at: CMTime(seconds: 1, preferredTimescale: 600), value: 1)
    #expect(k.value(at: .zero) == 1)
    #expect(k.value(at: CMTime(seconds: 10, preferredTimescale: 600)) == 1)
}

@Test("Keyframed<Float>: linearly interpolates between two keyframes")
func keyframesInterpolate() {
    var k = Keyframed<Float>(defaultValue: 0)
    k.addKeyframe(at: CMTime(seconds: 0, preferredTimescale: 600), value: 0)
    k.addKeyframe(at: CMTime(seconds: 2, preferredTimescale: 600), value: 1)
    // Midpoint at t=1s is 0.5.
    let mid = k.value(at: CMTime(seconds: 1, preferredTimescale: 600))
    #expect(abs(mid - 0.5) < 1e-6)
}

@Test("Keyframed<Float>: clamps to first / last beyond range")
func keyframesClamp() {
    var k = Keyframed<Float>(defaultValue: -1)
    k.addKeyframe(at: CMTime(seconds: 1, preferredTimescale: 600), value: 0)
    k.addKeyframe(at: CMTime(seconds: 2, preferredTimescale: 600), value: 1)
    #expect(k.value(at: .zero) == 0)
    #expect(k.value(at: CMTime(seconds: 10, preferredTimescale: 600)) == 1)
}

@Test("Keyframed<Float>: addKeyframe replaces an exact-time entry instead of duplicating")
func keyframesReplaceAtSameTime() {
    var k = Keyframed<Float>(defaultValue: 0)
    let t = CMTime(seconds: 1, preferredTimescale: 600)
    k.addKeyframe(at: t, value: 0.3)
    k.addKeyframe(at: t, value: 0.7)
    #expect(k.keyframes.count == 1)
    #expect(k.value(at: t) == 0.7)
}

@Test("Keyframed<Float>: removeKeyframe drops by id")
func keyframesRemove() {
    var k = Keyframed<Float>(defaultValue: 0)
    k.addKeyframe(at: CMTime(seconds: 1, preferredTimescale: 600), value: 0.3)
    let id = k.keyframes[0].id
    k.removeKeyframe(id: id)
    #expect(k.keyframes.isEmpty)
}

@Test("Keyframed<Float>: Codable round-trips")
func keyframesRoundTrip() throws {
    var k = Keyframed<Float>(defaultValue: 0.1)
    k.addKeyframe(at: CMTime(seconds: 0.5, preferredTimescale: 600), value: 0.25)
    k.addKeyframe(at: CMTime(seconds: 1.5, preferredTimescale: 600), value: 0.75)
    let data = try JSONEncoder().encode(k)
    let back = try JSONDecoder().decode(Keyframed<Float>.self, from: data)
    #expect(back == k)
}

// MARK: - SRT importer (feature-caption-tracks R5.1)

@Test("SRT: parses a single well-formed cue")
func srtSingleCue() throws {
    let raw = """
    1
    00:00:01,000 --> 00:00:04,500
    Hello world

    """
    let track = try CaptionImporter.importTrack(data: Data(raw.utf8), isVTT: false, name: "T")
    #expect(track.lines.count == 1)
    let line = track.lines[0]
    #expect(line.text == "Hello world")
    #expect(line.range.start.seconds == 1)
    #expect(abs(line.range.end.seconds - 4.5) < 1e-6)
}

@Test("SRT: handles CRLF line endings and multi-line text")
func srtCRLF() throws {
    let raw = "1\r\n00:00:00,500 --> 00:00:03,000\r\nFirst line\r\nSecond line\r\n\r\n"
    let lines = CaptionImporter.parseSRT(raw)
    #expect(lines.count == 1)
    #expect(lines[0].text == "First line\nSecond line")
}

@Test("SRT: skips a malformed block but keeps subsequent valid cues")
func srtMalformedSkipped() throws {
    let raw = """
    1
    not-a-timing-line
    Garbage cue

    2
    00:00:02,000 --> 00:00:04,000
    Valid cue

    """
    let lines = CaptionImporter.parseSRT(raw)
    #expect(lines.count == 1)
    #expect(lines[0].text == "Valid cue")
}

@Test("SRT: rejects non-UTF8 input")
func srtNonUTF8() {
    let bytes: [UInt8] = [0xFF, 0xFE, 0xFD]
    #expect(throws: CaptionImporter.ImportError.self) {
        _ = try CaptionImporter.importTrack(data: Data(bytes), isVTT: false, name: "X")
    }
}

// MARK: - VTT importer (R5.2)

@Test("VTT: WEBVTT header required")
func vttHeaderRequired() {
    let raw = "00:00:01.000 --> 00:00:02.000\nNo header\n"
    #expect(throws: CaptionImporter.ImportError.self) {
        _ = try CaptionImporter.importTrack(data: Data(raw.utf8), isVTT: true, name: "T")
    }
}

@Test("VTT: skips NOTE and STYLE blocks but keeps cues")
func vttSkipsMetaBlocks() throws {
    let raw = """
    WEBVTT

    NOTE Some metadata

    STYLE
    ::cue { color: red }

    00:00:01.000 --> 00:00:02.500
    Real cue

    """
    let lines = try CaptionImporter.parseVTT(raw)
    #expect(lines.count == 1)
    #expect(lines[0].text == "Real cue")
}

@Test("VTT: accepts cue with optional identifier line and hh prefix")
func vttIdentifierAndHours() throws {
    let raw = """
    WEBVTT

    intro
    00:00:00.000 --> 00:00:01.500
    Intro

    second
    01:00:00.000 --> 01:00:02.000
    Hour mark

    """
    let lines = try CaptionImporter.parseVTT(raw)
    #expect(lines.count == 2)
    #expect(lines[0].text == "Intro")
    #expect(lines[1].range.start.seconds == 3600)
}

// MARK: - Caption track persistence (R5.3)

@Test("ProjectDocument: round-trips caption tracks and lines losslessly")
func captionPersistenceRoundTrip() throws {
    let project = Project()
    let track = CaptionTrack(name: "Captions")
    track.addLine(CaptionLine(
        range: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                           duration: CMTime(seconds: 2, preferredTimescale: 600)),
        text: "Hello",
        words: [WordTiming(
            range: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                               duration: CMTime(seconds: 1, preferredTimescale: 600)),
            word: "Hello")]))
    track.defaultStyle = BuiltInCaptionPresets.socialBoldYellow.style
    project.captionTracks = [track]

    let doc = ProjectDocument(project: project)
    let data = try doc.encoded()
    let back = try ProjectDocument(data: data)
    #expect(back.captionTracks.count == 1)
    let restored = back.captionTracks[0]
    #expect(restored.name == "Captions")
    #expect(restored.lines.count == 1)
    #expect(restored.lines[0].text == "Hello")
    #expect(restored.lines[0].words?.count == 1)
    #expect(restored.defaultStyle == BuiltInCaptionPresets.socialBoldYellow.style)
}

@Test("ProjectDocument: legacy document without captionTracks decodes to empty")
func captionPersistenceLegacyDoc() throws {
    let legacyJSON = """
    {
      "name": "Old",
      "schemaVersion": 1,
      "renderWidth": 1920, "renderHeight": 1080, "frameRate": 30,
      "media": [], "videoTracks": [], "audioTracks": []
    }
    """
    let doc = try ProjectDocument(data: Data(legacyJSON.utf8))
    #expect(doc.captionTracks.isEmpty)
}

// MARK: - Project.duration with caption tail (R5.4)

@Test("Project.duration: extends to the latest caption line end")
func projectDurationCaptionTail() {
    let project = Project()
    let track = CaptionTrack(name: "T")
    track.addLine(CaptionLine(
        range: CMTimeRange(start: CMTime(seconds: 5, preferredTimescale: 600),
                           duration: CMTime(seconds: 2, preferredTimescale: 600)),
        text: "Tail"))
    project.captionTracks = [track]
    // No clips ⇒ duration is the latest caption end (7s).
    #expect(abs(project.duration.seconds - 7) < 1e-6)
}

// MARK: - CaptionStyle clamp + hash (Phase 30 R2.2)

@Test("CaptionStyle: clamp enforces ranges")
func captionStyleClamp() {
    var style = CaptionStyle()
    style.fontSize = 9000
    style.enterDuration = 10
    style.stroke.width = 200
    style.clamp()
    #expect(style.fontSize == 512)
    #expect(style.enterDuration == 5)
    #expect(style.stroke.width == 64)
}

@Test("CaptionStyle: rasterHash changes when a pixel-affecting field changes")
func captionStyleRasterHash() {
    let a = CaptionStyle()
    var b = a
    b.fontSize = 80
    #expect(a.rasterHash != b.rasterHash)
}

@Test("CaptionStyle: rasterHash ignores animation timing")
func captionStyleRasterHashIgnoresAnimation() {
    let a = CaptionStyle()
    var b = a
    b.enterDuration = 1
    b.exitDuration = 1
    b.enterAnimation = .pop
    b.exitAnimation = .fade
    #expect(a.rasterHash == b.rasterHash)
}

// MARK: - Animation evaluator (Phase 30 R3.2)

@Test("Animation: pop is identity outside the enter window")
func animationPopIdentityPastEnter() {
    var style = CaptionStyle()
    style.enterAnimation = .pop
    style.enterDuration = 0.2
    let frame = CaptionAnimation.evaluate(
        currentTime: CMTime(seconds: 1, preferredTimescale: 600),
        lineStart: .zero,
        lineEnd: CMTime(seconds: 5, preferredTimescale: 600),
        style: style)
    #expect(frame.scale == 1)
    #expect(frame.opacity == 1)
    #expect(frame.translation == .zero)
}

@Test("Animation: pop scales and fades up over enter window")
func animationPopRamp() {
    var style = CaptionStyle()
    style.enterAnimation = .pop
    style.enterDuration = 0.2
    let start = CMTime.zero
    let end = CMTime(seconds: 5, preferredTimescale: 600)
    let frame0 = CaptionAnimation.evaluate(currentTime: .zero, lineStart: start, lineEnd: end, style: style)
    let frame1 = CaptionAnimation.evaluate(
        currentTime: CMTime(seconds: 0.1, preferredTimescale: 600),
        lineStart: start, lineEnd: end, style: style)
    #expect(frame0.scale < frame1.scale)
    #expect(frame0.opacity < frame1.opacity)
}

@Test("Animation: typewriter progress ramps 0→1 across enter")
func animationTypewriterRamp() {
    var style = CaptionStyle()
    style.enterAnimation = .typewriter
    style.enterDuration = 1
    let start = CMTime.zero
    let end = CMTime(seconds: 5, preferredTimescale: 600)
    let half = CaptionAnimation.evaluate(
        currentTime: CMTime(seconds: 0.5, preferredTimescale: 600),
        lineStart: start, lineEnd: end, style: style)
    #expect(abs(half.typewriterProgress - 0.5) < 0.01)
}

@Test("Animation: fade exit drives opacity to zero at line end")
func animationFadeExit() {
    var style = CaptionStyle()
    style.exitAnimation = .fade
    style.exitDuration = 0.5
    let start = CMTime.zero
    let end = CMTime(seconds: 2, preferredTimescale: 600)
    let atEnd = CaptionAnimation.evaluate(
        currentTime: end,
        lineStart: start, lineEnd: end, style: style)
    #expect(atEnd.opacity == 0)
}

// MARK: - Preset round-trip (Phase 30 R4.2)

@Test("CaptionPresetV1: encode/decode round-trip")
func presetRoundTrip() throws {
    let preset = BuiltInCaptionPresets.socialBoldYellow
    let data = try CaptionPresetIO.encode(preset)
    let back = try CaptionPresetIO.decode(data)
    #expect(back == preset)
}

@Test("CaptionPresetV1: rejects unknown version")
func presetUnknownVersion() {
    let json = """
    {"version":"99","name":"X","family":"social","style":{}}
    """
    #expect(throws: CaptionPresetIO.IOError.self) {
        _ = try CaptionPresetIO.decode(Data(json.utf8))
    }
}

@Test("BuiltInCaptionPresets: ships at least ten presets covering ≥3 families")
func presetLibraryShape() {
    let presets = BuiltInCaptionPresets.all
    #expect(presets.count >= 10)
    let families = Set(presets.map(\.family))
    #expect(families.count >= 3)
}

// MARK: - Title rasterer (feature-title-raster T2.1–T2.5)

@Test("TitleRasterer: identical requests hit the cache exactly once")
func titleRastererCacheHit() {
    final class Counter: @unchecked Sendable { nonisolated(unsafe) var n = 0 }
    let counter = Counter()
    let r = TitleRasterer(capacity: 4)
    let id = UUID()
    let req = TitleRasterRequest(lineID: id, styleHash: 0, text: "hi",
                                 renderSize: CGSize(width: 64, height: 32))
    let first = r.raster(for: req) { _, _ in counter.n += 1; return CGRect(x: 0, y: 0, width: 10, height: 10) }
    let second = r.raster(for: req) { _, _ in counter.n += 1; return CGRect(x: 0, y: 0, width: 10, height: 10) }
    #expect(counter.n == 1)
    #expect(first.boundingBox == second.boundingBox)
    #expect(r.count == 1)
}

@Test("TitleRasterer: distinct keys produce separate cache entries")
func titleRastererKeySeparation() {
    let r = TitleRasterer(capacity: 16)
    let id = UUID()
    let canvas = CGSize(width: 64, height: 32)
    _ = r.raster(for: TitleRasterRequest(lineID: id, styleHash: 1, text: "a", renderSize: canvas)) { _, _ in .zero }
    _ = r.raster(for: TitleRasterRequest(lineID: id, styleHash: 2, text: "a", renderSize: canvas)) { _, _ in .zero }
    _ = r.raster(for: TitleRasterRequest(lineID: id, styleHash: 1, text: "b", renderSize: canvas)) { _, _ in .zero }
    _ = r.raster(for: TitleRasterRequest(lineID: id, styleHash: 1, text: "a", renderSize: CGSize(width: 128, height: 64))) { _, _ in .zero }
    #expect(r.count == 4)
}

@Test("TitleRasterer: LRU eviction at capacity")
func titleRastererLRU() {
    let r = TitleRasterer(capacity: 2)
    let canvas = CGSize(width: 64, height: 32)
    let id = UUID()
    _ = r.raster(for: TitleRasterRequest(lineID: id, styleHash: 1, text: "a", renderSize: canvas)) { _, _ in .zero }
    _ = r.raster(for: TitleRasterRequest(lineID: id, styleHash: 2, text: "b", renderSize: canvas)) { _, _ in .zero }
    _ = r.raster(for: TitleRasterRequest(lineID: id, styleHash: 3, text: "c", renderSize: canvas)) { _, _ in .zero }
    #expect(r.count == 2)
}

@Test("TitleRasterer: purge empties the cache")
func titleRastererPurge() {
    let r = TitleRasterer(capacity: 4)
    let req = TitleRasterRequest(lineID: UUID(), styleHash: 1, text: "x",
                                 renderSize: CGSize(width: 32, height: 32))
    _ = r.raster(for: req) { _, _ in CGRect(x: 0, y: 0, width: 4, height: 4) }
    #expect(r.count == 1)
    r.purge()
    #expect(r.count == 0)
}
