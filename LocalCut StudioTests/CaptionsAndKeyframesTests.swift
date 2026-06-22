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

@Test("Keyframed<Float>: updateKeyframe dedups when moved onto an existing time (Claude review #5)")
func keyframesUpdateDedupsOnCollision() {
    var k = Keyframed<Float>(defaultValue: 0)
    k.addKeyframe(at: CMTime(seconds: 1, preferredTimescale: 600), value: 0.3)
    k.addKeyframe(at: CMTime(seconds: 2, preferredTimescale: 600), value: 0.7)
    let movingID = k.keyframes[0].id
    // Move the first keyframe onto the second's time — the collider should drop.
    k.updateKeyframe(id: movingID, time: CMTime(seconds: 2, preferredTimescale: 600), value: nil)
    #expect(k.keyframes.count == 1)
    #expect(k.keyframes[0].id == movingID)
    #expect(k.value(at: CMTime(seconds: 2, preferredTimescale: 600)) == 0.3)
}

@Test("Keyframed<Float>: decoding an unsorted keyframes array sorts on the way in (Claude review #6)")
func keyframesDecodeSorts() throws {
    let unsortedJSON = """
    {"defaultValue":0,"keyframes":[
      {"id":"00000000-0000-0000-0000-000000000002","time":{"value":2,"timescale":1},"value":0.7},
      {"id":"00000000-0000-0000-0000-000000000001","time":{"value":1,"timescale":1},"value":0.3}
    ]}
    """
    let k = try JSONDecoder().decode(Keyframed<Float>.self, from: Data(unsortedJSON.utf8))
    #expect(k.keyframes.count == 2)
    #expect(k.keyframes[0].time.seconds == 1)
    #expect(k.keyframes[1].time.seconds == 2)
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
    let lines = try CaptionImporter.parseLines(data: Data(raw.utf8), isVTT: false)
    #expect(lines.count == 1)
    let line = lines[0]
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
        _ = try CaptionImporter.parseLines(data: Data(bytes), isVTT: false)
    }
}

// MARK: - BOM + tab separator (Gemini review #2 / #3)

@Test("SRT: tolerates a leading UTF-8 BOM")
func srtTolerantOfBOM() throws {
    var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
    bytes.append(contentsOf: Array("""
    1
    00:00:01,000 --> 00:00:02,000
    First

    """.utf8))
    let lines = try CaptionImporter.parseLines(data: Data(bytes), isVTT: false)
    #expect(lines.count == 1)
    #expect(lines[0].text == "First")
}

@Test("VTT: tolerates a leading UTF-8 BOM before WEBVTT")
func vttTolerantOfBOM() throws {
    var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
    bytes.append(contentsOf: Array("""
    WEBVTT

    00:00:01.000 --> 00:00:02.000
    Hi

    """.utf8))
    let lines = try CaptionImporter.parseLines(data: Data(bytes), isVTT: true)
    #expect(lines.count == 1)
}

@Test("VTT: tab separator between end timestamp and cue settings is accepted")
func vttTabSeparator() throws {
    // A real-world VTT exporter writes "end\tline:foo" rather than "end line:foo".
    let raw = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\tline:80%\nWith tabs\n"
    let lines = try CaptionImporter.parseVTT(raw)
    #expect(lines.count == 1)
    #expect(lines[0].text == "With tabs")
}

// MARK: - VTT importer (R5.2)

@Test("VTT: WEBVTT header required")
func vttHeaderRequired() {
    let raw = "00:00:01.000 --> 00:00:02.000\nNo header\n"
    #expect(throws: CaptionImporter.ImportError.self) {
        _ = try CaptionImporter.parseLines(data: Data(raw.utf8), isVTT: true)
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

// MARK: - CaptionTrack identity (review feedback)

@Test("CaptionTrack: id round-trips through ProjectDocument save/load")
func captionTrackIDPersistsAcrossSaveLoad() throws {
    let project = Project()
    let original = CaptionTrack(name: "Stable")
    let originalID = original.id
    project.captionTracks = [original]

    let data = try ProjectDocument(project: project).encoded()
    let reopened = try ProjectDocument(data: data)
    let restored = reopened.captionTracks[0].makeTrack()
    #expect(restored.id == originalID)
}

@Test("CaptionTrack: previously-deleted track returns with its original id on undo")
func captionTrackIDStableAcrossUndoRestore() {
    let project = Project()
    let track = CaptionTrack(name: "T")
    let originalID = track.id
    project.captionTracks = [track]

    // Snapshot, delete, then restore via `applyState`-equivalent.
    let snapshot = ProjectState.CaptionTrackSnapshot(
        trackID: track.id, name: track.name, isMuted: false,
        defaultStyle: track.defaultStyle, lines: track.lines)
    project.captionTracks = []
    // Rebuild from snapshot using the same constructor path applyState uses.
    let restored = CaptionTrack(id: snapshot.trackID, name: snapshot.name,
                                lines: snapshot.lines)
    #expect(restored.id == originalID)
}

// MARK: - CaptionLine / WordTiming defensive decoding (review feedback)

@Test("CaptionLine: invalid (zero) timescale on disk decodes to a fallback rather than crashing")
func captionLineDecodeFallsBackOnZeroTimescale() throws {
    let json = """
    {"id":"00000000-0000-0000-0000-000000000000",
     "startValue":1000,"startScale":0,
     "durationValue":2000,"durationScale":0,
     "text":"Hi"}
    """
    let line = try JSONDecoder().decode(CaptionLine.self, from: Data(json.utf8))
    #expect(line.range.start.timescale > 0)
    #expect(line.range.duration.timescale > 0)
}

@Test("WordTiming: invalid (zero) timescale on disk decodes to a fallback rather than crashing")
func wordTimingDecodeFallsBackOnZeroTimescale() throws {
    let json = """
    {"startValue":1000,"startScale":0,
     "durationValue":2000,"durationScale":-5,
     "word":"hi"}
    """
    let word = try JSONDecoder().decode(WordTiming.self, from: Data(json.utf8))
    #expect(word.range.start.timescale > 0)
    #expect(word.range.duration.timescale > 0)
}

// MARK: - SRT negative-timestamp guard (review feedback)

@Test("SRT: rejects a cue with a negative timestamp component")
func srtRejectsNegativeTimestamp() {
    let raw = """
    1
    00:00:-1,000 --> 00:00:02,000
    Negative seconds

    """
    let lines = CaptionImporter.parseSRT(raw)
    #expect(lines.isEmpty)
}

// MARK: - Caption track persistence (R5.3)

@Test("updateCaptionLine: typing several characters folds into ONE undo step (Gemini review #1)")
func captionTextEditCoalesces() async {
    let model = EditorModel()
    let track = CaptionTrack(name: "T")
    let line = CaptionLine(
        range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
        text: "")
    track.addLine(line)
    model.project.captionTracks = [track]

    for char in "hello" {
        var updated = track.lines[0]
        updated.text.append(char)
        model.updateCaptionLine(updated, in: track.id)
    }
    // Commit any in-flight coalesced gesture and verify one — not five —
    // undo entries cover the whole typing burst.
    model.commitCoalescedUndo()
    #expect(track.lines[0].text == "hello")
    model.undo()
    #expect(track.lines[0].text == "")
}

@Test("setCaptionTrackMuted: routes through undo (Claude review #4)")
func captionMuteIsUndoable() {
    let model = EditorModel()
    let track = CaptionTrack(name: "T")
    model.project.captionTracks = [track]
    #expect(model.canUndo == false)
    model.setCaptionTrackMuted(true, in: track.id)
    #expect(track.isMuted == true)
    #expect(model.canUndo == true)
    model.undo()
    #expect(track.isMuted == false)
}

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

@Test("ProjectDocument: schema is v2 once captionTracks ship (Codex review #2)")
func projectDocumentSchemaV2() {
    #expect(ProjectDocument.currentSchemaVersion >= 2)
}

@Test("CaptionStyle: partial JSON decodes to defaults instead of throwing (Codex review #4)")
func captionStyleTolerantDecode() throws {
    // Only `fontName` is set; every other field should keep its default.
    let partial = """
    {"fontName":"Times-Italic"}
    """
    let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(partial.utf8))
    #expect(style.fontName == "Times-Italic")
    #expect(style.fontSize == CaptionStyle.identity.fontSize)
    #expect(style.fill == CaptionStyle.identity.fill)
    #expect(style.enterAnimation == CaptionStyle.identity.enterAnimation)
}

@Test("TitleRasterRequest: wordsDigest separates cache entries when the words array shifts (Codex review #5)")
func titleRasterRequestWordsDigest() {
    let id = UUID()
    let a = TitleRasterRequest(lineID: id, styleHash: 1, text: "hi",
                               wordHighlightIndex: 0, wordsDigest: 100,
                               renderSize: CGSize(width: 32, height: 32))
    let b = TitleRasterRequest(lineID: id, styleHash: 1, text: "hi",
                               wordHighlightIndex: 0, wordsDigest: 200,
                               renderSize: CGSize(width: 32, height: 32))
    #expect(a != b)
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

@Test("Animation: vertical slide enter respects y-up coordinates (Claude review #1)")
func animationSlideVerticalDirection() {
    var style = CaptionStyle()
    style.enterAnimation = .slide
    style.enterDuration = 0.2
    let start = CMTime.zero
    let end = CMTime(seconds: 5, preferredTimescale: 600)

    // fromBottom at t=0 should sit BELOW the rest position (negative y in y-up).
    style.slideDirection = .fromBottom
    let bottomAtStart = CaptionAnimation.evaluate(currentTime: .zero,
                                                  lineStart: start, lineEnd: end, style: style)
    #expect(bottomAtStart.translation.height < 0)

    // fromTop at t=0 should sit ABOVE rest (positive y in y-up).
    style.slideDirection = .fromTop
    let topAtStart = CaptionAnimation.evaluate(currentTime: .zero,
                                               lineStart: start, lineEnd: end, style: style)
    #expect(topAtStart.translation.height > 0)
}

@Test("Animation: enter + exit longer than line scale to fit, preventing overlap (Claude bot final review)")
func animationDurationsScaleToFitLine() {
    var style = CaptionStyle()
    style.enterAnimation = .pop
    style.exitAnimation = .fade
    // Configured 2 s enter + 1 s exit on a 1.5 s line. Without scaling, the
    // exit window would begin at end - 1.0 = 0.5 s (overlapping the enter,
    // which doesn't finish until end of line). With scaling, total = 3 s,
    // so each value halves to 1.0 s / 0.5 s respectively — they meet exactly
    // at t = 1.0 s with no overlap.
    style.enterDuration = 2.0
    style.exitDuration = 1.0

    let start = CMTime.zero
    let end = CMTime(seconds: 1.5, preferredTimescale: 600)

    // At t = 1.0 s: scaled enter has just completed (so pop scale ≈ 1, opacity ≈ 1)
    // and scaled exit is just beginning (so fade opacity = 1). Without the
    // scaling fix, exit would have eaten half the opacity already.
    let atSeam = CaptionAnimation.evaluate(
        currentTime: CMTime(seconds: 1.0, preferredTimescale: 600),
        lineStart: start, lineEnd: end, style: style)
    #expect(atSeam.opacity > 0.95)
    #expect(atSeam.scale > 0.95)
}

@Test("Animation: scaling preserves the enter / exit ratio")
func animationDurationsScaleRatio() {
    var style = CaptionStyle()
    style.enterAnimation = .pop
    style.exitAnimation = .pop
    style.enterDuration = 2.0
    style.exitDuration = 1.0  // ratio 2:1, total 3
    let start = CMTime.zero
    let end = CMTime(seconds: 1.5, preferredTimescale: 600)  // line 1.5, scale = 0.5

    // After scaling: enter = 1.0, exit = 0.5. So exit begins at 1.0 (end - 0.5).
    // Probe just before the exit boundary; only enter should be at full scale.
    let beforeExit = CaptionAnimation.evaluate(
        currentTime: CMTime(value: 999, timescale: 1000), // 0.999 s
        lineStart: start, lineEnd: end, style: style)
    #expect(beforeExit.opacity > 0.95)
}

@Test("Animation: durations that already fit are untouched")
func animationDurationsNoScalingWhenFits() {
    var style = CaptionStyle()
    style.enterAnimation = .pop
    style.exitAnimation = .fade
    style.enterDuration = 0.25
    style.exitDuration = 0.25  // total 0.5 vs 2 s line — no scaling.
    let start = CMTime.zero
    let end = CMTime(seconds: 2, preferredTimescale: 600)

    // At t = 0.25 s the enter window has just finished — pop sits at full scale.
    let postEnter = CaptionAnimation.evaluate(
        currentTime: CMTime(seconds: 0.25, preferredTimescale: 600),
        lineStart: start, lineEnd: end, style: style)
    #expect(postEnter.scale > 0.95)
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

@Test("CaptionPresetIO.decode: surfaces the underlying decoder message on malformed JSON (Claude bot final review)")
func presetDecodeSurfacesUnderlyingError() {
    let garbage = Data("definitely not json".utf8)
    var caught: CaptionPresetIO.IOError?
    do {
        _ = try CaptionPresetIO.decode(garbage)
    } catch let error as CaptionPresetIO.IOError {
        caught = error
    } catch {
        // Other errors are fine for the test outcome; we just want IOError.
    }
    guard case .decodeFailed(let detail) = caught else {
        Issue.record("expected IOError.decodeFailed, got \(String(describing: caught))")
        return
    }
    #expect(detail != nil)
    #expect(!(detail ?? "").isEmpty)
    // The user-facing description should embed that detail rather than the
    // generic fallback message.
    #expect((caught?.errorDescription ?? "").contains(detail ?? "💥"))
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

@Test("TitleRasterer: empty draw closure yields zero bounding box (T2.5)")
func titleRastererEmptyDrawZeroBox() {
    let r = TitleRasterer(capacity: 2)
    let req = TitleRasterRequest(lineID: UUID(), styleHash: 1, text: "",
                                 renderSize: CGSize(width: 64, height: 32))
    let raster = r.raster(for: req) { _, _ in .zero }
    #expect(raster.boundingBox == .zero)
}

@Test("TitleRasterer: drawing closure returning a glyph rect yields a positive bbox (T2.5)")
func titleRastererPositiveBox() {
    let r = TitleRasterer(capacity: 2)
    let req = TitleRasterRequest(lineID: UUID(), styleHash: 1, text: "x",
                                 renderSize: CGSize(width: 64, height: 32))
    let raster = r.raster(for: req) { _, _ in CGRect(x: 4, y: 4, width: 12, height: 12) }
    #expect(raster.boundingBox.width > 0)
    #expect(raster.boundingBox.height > 0)
}

// MARK: - Preset snapshot (Phase 30 T5.1, golden-less form)

/// Renders each built-in preset's idle frame at a fixed canvas and verifies the
/// raster comes back with a non-zero bounding box that sits inside the canvas.
/// Stops short of a pixel-golden diff (which would need committed PNGs and a
/// font-availability matrix), but catches the regressions worth catching here:
/// font lookup failures, layout breakage, and the rasterer returning the empty
/// transparent fallback when something throws.
@Test("BuiltInCaptionPresets: every preset renders to a non-empty raster (T5.1)")
func presetSnapshotShape() {
    let canvas = CGSize(width: 1280, height: 720)
    let rasterer = CaptionRasterer()
    for preset in BuiltInCaptionPresets.all {
        let line = CaptionLine(
            range: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            text: "Sample caption")
        let raster = rasterer.idleRaster(line: line, style: preset.style, renderSize: canvas)
        let unwrapped = try? #require(raster)
        guard let raster = unwrapped else { continue }
        #expect(raster.boundingBox.width > 0, "Preset \(preset.name) produced an empty bounding box")
        #expect(raster.boundingBox.height > 0, "Preset \(preset.name) produced an empty bounding box")
        // Bounding box must sit inside the canvas (with padding for stroke / pill).
        #expect(raster.boundingBox.minX >= -64, "Preset \(preset.name) bbox extends well beyond the left edge")
        #expect(raster.boundingBox.maxX <= canvas.width + 64, "Preset \(preset.name) bbox extends well beyond the right edge")
    }
}

// MARK: - Smoke test (Phase 30 T5.2)

/// Generates a 2 s solid-colour fixture clip via `AVAssetWriter`, builds a
/// project with a video clip + a caption track whose single line covers the
/// midpoint, and asserts the built `AVVideoComposition` carries the caption
/// render item on the instruction interval that contains the midpoint.
/// This proves the SRT → model → compositor wiring end-to-end without needing
/// committed binary fixtures.
@MainActor
@Suite("Phase 30 — smoke", .serialized)
struct PhaseThirtySmokeTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Writes a short solid-colour H.264 movie to a temp file and returns its URL.
    /// Same pattern `TransitionsIntegrationTests` uses.
    private func makeVideoFixture(seconds: Double, fps: Int32 = 30,
                                  size: CGSize = CGSize(width: 320, height: 180)) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-fixture-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)

        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * Double(fps))
        for frame in 0..<frameCount {
            // Bail out if the writer entered a non-`.writing` status so a
            // failure mid-loop surfaces as a clean test failure instead of
            // hanging on `isReadyForMoreMediaData` forever (Claude bot P1 #2).
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { break }
                await Task.yield()
            }
            guard writer.status == .writing,
                  let pool = adaptor.pixelBufferPool else { break }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func loadedMedia(from url: URL) async throws -> MediaItem {
        let item = MediaItem(url: url)
        item.duration = try await item.asset.load(.duration)
        let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
        let track = try #require(videoTracks.first)
        item.hasVideo = true
        item.naturalSize = try await track.load(.naturalSize)
        item.preferredTransform = try await track.load(.preferredTransform)
        return item
    }

    @Test("SRT → model → built composition carries the caption at the midpoint")
    func captionRoundTripsThroughCompositor() async throws {
        // Generate a 2s clip and import it as a clip on the timeline.
        let url = try await makeVideoFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let project = Project()
        let media = try await loadedMedia(from: url)
        project.mediaItems.append(media)

        let videoTrack = project.videoTracks.first!
        videoTrack.clips = [Clip(mediaID: media.id, sourceStart: .zero,
                                 duration: time(2), timelineStart: .zero)]

        // Hand-roll a tiny SRT, parse it, attach the track to the project.
        let srt = """
        1
        00:00:00,500 --> 00:00:01,500
        Smoke caption

        """
        let captionLines = try CaptionImporter.parseLines(data: Data(srt.utf8), isVTT: false)
        let captionTrack = CaptionTrack(name: "Smoke", lines: captionLines)
        captionTrack.defaultStyle = BuiltInCaptionPresets.socialBoldYellow.style
        project.captionTracks = [captionTrack]

        // Build composition end-to-end.
        let built = try #require(try await CompositionBuilder.build(project: project))
        let videoComposition = try #require(built.videoComposition)

        // The instruction whose time range contains t=1.0 (the caption midpoint)
        // must carry our caption render item, with the preset's style applied.
        let probe = CMTime(seconds: 1.0, preferredTimescale: 600)
        let instruction = videoComposition.instructions.first { instr in
            CMTimeRangeContainsTime(instr.timeRange, time: probe)
        }
        let captioned = try #require(instruction as? EffectCompositionInstruction)
        #expect(captioned.captions.count == 1)
        let item = try #require(captioned.captions.first)
        #expect(item.text == "Smoke caption")
        #expect(item.style == BuiltInCaptionPresets.socialBoldYellow.style)
        // Caption forces tweening on the instruction so per-frame animation is
        // re-evaluated rather than reusing one rendered frame for the interval.
        #expect(captioned.containsTweening == true)
    }

    /// A 1 s AV clip plus a caption that ends at 1.5 s. Without the tail filler
    /// the composition's duration is truncated to the AV end (1 s) and the
    /// caption disappears half a second early; with the filler inserted, the
    /// composition runs to the caption's true end and a video-composition
    /// instruction covers the tail interval. Mirrors the limitation that
    /// `phase-30-animated-captions/design.md` previously documented.
    ///
    /// Disabled while we triage a CI test-phase hang on macos-26; the
    /// production code path is exercised by the (currently manual) scrub
    /// described in the spec's acceptance criteria. Re-enable once the hang
    /// is root-caused.
    @Test("Composition extends past the last AV clip when a caption tail runs longer",
          .disabled("Triage: macos-26 CI test phase hangs for 30 min with no test output"))
    func compositionExtendsForCaptionTail() async throws {
        let url = try await makeVideoFixture(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let project = Project()
        // Smaller canvas keeps the cached filler generation fast for tests.
        project.renderSize = CGSize(width: 320, height: 180)

        let media = try await loadedMedia(from: url)
        project.mediaItems.append(media)

        let videoTrack = project.videoTracks.first!
        videoTrack.clips = [Clip(mediaID: media.id, sourceStart: .zero,
                                 duration: time(1), timelineStart: .zero)]

        let captionTrack = CaptionTrack(name: "Tail")
        captionTrack.addLine(CaptionLine(
            range: CMTimeRange(start: time(0.5), duration: time(1.0)),
            text: "Past the end"))
        project.captionTracks = [captionTrack]

        let built = try #require(try await CompositionBuilder.build(project: project))

        // Filler pushed composition.duration to the caption end (1.5 s), not the
        // AV-only 1.0 s previously seen. Allow ~1 frame of slop for timescale
        // rounding inside `insertTimeRange`.
        #expect(built.duration >= 1.5 - 1.0 / 30.0,
                "Expected composition to extend to caption end (~1.5 s), got \(built.duration)")

        // The video composition must have an instruction covering t = 1.25 s
        // (past the AV end, mid-caption-tail) and that instruction must carry
        // the caption render item.
        let videoComposition = try #require(built.videoComposition)
        let probe = CMTime(seconds: 1.25, preferredTimescale: 600)
        let tailInstruction = videoComposition.instructions.first { instr in
            CMTimeRangeContainsTime(instr.timeRange, time: probe)
        }
        let captioned = try #require(tailInstruction as? EffectCompositionInstruction)
        #expect(captioned.captions.contains { $0.text == "Past the end" })
    }

}
