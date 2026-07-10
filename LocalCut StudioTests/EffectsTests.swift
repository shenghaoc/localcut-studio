import Testing
import AVFoundation
import CoreGraphics
import CoreImage
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - T1.2 Unit tests

@Test("ColourGrade neutral defaults are identity")
func neutralDefaults() {
    let grade = ColourGrade()
    #expect(grade.exposure == 0)
    #expect(grade.contrast == 1)
    #expect(grade.saturation == 1)
    #expect(grade.temperatureOffset == 0)
    #expect(grade.tintOffset == 0)
}

@Test("ColourGrade.clamp() enforces documented ranges")
func clamping() {
    var grade = ColourGrade()
    grade.exposure = 5
    grade.contrast = 3
    grade.saturation = -1
    grade.temperatureOffset = 5000
    grade.tintOffset = 200
    grade.clamp()
    #expect(grade.exposure == 2)
    #expect(grade.contrast == 1.5)
    #expect(grade.saturation == 0)
    #expect(grade.temperatureOffset == 4000)
    #expect(grade.tintOffset == 150)
}

@Test("ColourGrade.clamp() preserves in-range values")
func noClampingWhenInRange() {
    var grade = ColourGrade()
    grade.exposure = -1
    grade.contrast = 0.8
    grade.saturation = 1.5
    grade.temperatureOffset = 1000
    grade.tintOffset = -50
    grade.clamp()
    #expect(grade.exposure == -1)
    #expect(grade.contrast == 0.8)
    #expect(grade.saturation == 1.5)
    #expect(grade.temperatureOffset == 1000)
    #expect(grade.tintOffset == -50)
}

// MARK: - LUT slot helpers (feature-colour-grading R1.2)

// Custom parameterisation type for the LUT operation tests.
// We pre-build concrete cases so the test body can assert cleanly.
struct LUTTestScenario: Sendable, CustomTestStringConvertible {
    let scenarioDescription: String
    let inputEffects: [Effect]
    var testDescription: String { scenarioDescription }
    var description: String { scenarioDescription }
    let removeInstead: Bool
    let bookmark: Data
    let expectedLUTCount: Int
    let expectedTotalCount: Int
    let expectedFirstLUTBookmark: Data?
    let expectedContainsColourGrade: Bool
    let expectedContainsSkinSmooth: Bool
}

@Test("LUT operations: replace and remove",
      arguments: [
        LUTTestScenario(
            scenarioDescription: "appending LUT when none present",
            inputEffects: [.colourGrade(.neutral)],
            removeInstead: false,
            bookmark: Data([0x01]),
            expectedLUTCount: 1,
            expectedTotalCount: 2,
            expectedFirstLUTBookmark: nil,
            expectedContainsColourGrade: true,
            expectedContainsSkinSmooth: false
        ),
        LUTTestScenario(
            scenarioDescription: "replacing existing LUT in place",
            inputEffects: [.lut(bookmark: Data([0x01])), .colourGrade(.neutral)],
            removeInstead: false,
            bookmark: Data([0x02]),
            expectedLUTCount: 1,
            expectedTotalCount: 2,
            expectedFirstLUTBookmark: Data([0x02]),
            expectedContainsColourGrade: true,
            expectedContainsSkinSmooth: false
        ),
        LUTTestScenario(
            scenarioDescription: "collapsing stacked LUTs to single slot",
            inputEffects: [.lut(bookmark: Data([0x01])), .colourGrade(.neutral), .lut(bookmark: Data([0x02]))],
            removeInstead: false,
            bookmark: Data([0x09]),
            expectedLUTCount: 1,
            expectedTotalCount: 2,
            expectedFirstLUTBookmark: Data([0x09]),
            expectedContainsColourGrade: true,
            expectedContainsSkinSmooth: false
        ),
        LUTTestScenario(
            scenarioDescription: "removing LUT preserves grade + skin-smooth",
            inputEffects: [.colourGrade(.neutral), .lut(bookmark: Data([0x01])), .skinSmooth(.neutral)],
            removeInstead: true,
            bookmark: Data(), // unused for remove
            expectedLUTCount: 0,
            expectedTotalCount: 2,
            expectedFirstLUTBookmark: nil,
            expectedContainsColourGrade: true,
            expectedContainsSkinSmooth: true
        ),
      ])
func lutOperations(scenario: LUTTestScenario) {
    let result: [Effect]
    if scenario.removeInstead {
        result = scenario.inputEffects.removingLUT()
    } else {
        result = scenario.inputEffects.replacingLUT(bookmark: scenario.bookmark)
    }

    let lutCount = result.filter { if case .lut = $0 { return true }; return false }.count
    #expect(lutCount == scenario.expectedLUTCount, "\(scenario.description): expected \(scenario.expectedLUTCount) LUTs, got \(lutCount)")
    #expect(result.count == scenario.expectedTotalCount, "\(scenario.description): expected \(scenario.expectedTotalCount) effects total")

    if let expectedBookmark = scenario.expectedFirstLUTBookmark {
        if case .lut(let bookmark) = result.first {
            #expect(bookmark == expectedBookmark, "\(scenario.description): first LUT bookmark mismatch")
        } else {
            Issue.record("\(scenario.description): first effect should be the LUT")
        }
    }

    if scenario.expectedContainsColourGrade {
        #expect(result.contains { if case .colourGrade = $0 { return true }; return false },
                "\(scenario.description): colourGrade should be preserved")
    }
    if scenario.expectedContainsSkinSmooth {
        #expect(result.contains { if case .skinSmooth = $0 { return true }; return false },
                "\(scenario.description): skinSmooth should be preserved")
    }
}

@MainActor
@Test("EditorModel prunes stale LUT display names after replace and remove")
func lutDisplayNameCachePrunesStaleEntries() {
    let model = EditorModel()
    let media = MediaItem(url: URL(filePath: "/dev/null"))
    model.project.mediaItems.append(media)
    let first = Data([0x01])
    let second = Data([0x02])
    let clip = Clip(mediaID: media.id,
                    sourceStart: .zero,
                    duration: CMTime(seconds: 5, preferredTimescale: 600),
                    timelineStart: .zero)
    var effected = clip
    effected.effects = [.lut(bookmark: first)]
    model.project.videoTracks.first!.clips = [effected]
    model.selectedClipID = clip.id
    model._testCacheLUTDisplayName("first.cube", for: first)
    model._testPruneLUTDisplayNames()
    #expect(model.selectedClipLUTName == "first.cube")
    #expect(model._testLUTDisplayNameCacheCount == 1)

    model._testCacheLUTDisplayName("second.cube", for: second)
    model.project.videoTracks.first!.clips[0].effects =
        model.project.videoTracks.first!.clips[0].effects.replacingLUT(bookmark: second)
    model._testPruneLUTDisplayNames()
    #expect(model.selectedClipLUTName == "second.cube")
    #expect(model._testLUTDisplayNameCacheCount == 1)

    model.project.videoTracks.first!.clips[0].effects =
        model.project.videoTracks.first!.clips[0].effects.removingLUT()
    model._testPruneLUTDisplayNames()
    #expect(model.selectedClipLUTName == nil)
    #expect(model._testLUTDisplayNameCacheCount == 0)
}

@MainActor
@Test("EditorModel restores LUT display names across undo and redo")
func lutDisplayNameCacheRestoresWithUndoRedo() {
    let model = EditorModel()
    let media = MediaItem(url: URL(filePath: "/dev/null"))
    model.project.mediaItems.append(media)
    let first = Data([0x11])
    let second = Data([0x22])
    let clip = Clip(mediaID: media.id,
                    sourceStart: .zero,
                    duration: CMTime(seconds: 5, preferredTimescale: 600),
                    timelineStart: .zero)
    var effected = clip
    effected.effects = [.lut(bookmark: first)]
    model.project.videoTracks.first!.clips = [effected]
    model.selectedClipID = clip.id
    model._testCacheLUTDisplayName("first.cube", for: first)
    model._testPruneLUTDisplayNames()

    model.performUndoable("Replace LUT") {
        model._testCacheLUTDisplayName("second.cube", for: second)
        model.project.videoTracks.first!.clips[0].effects =
            model.project.videoTracks.first!.clips[0].effects.replacingLUT(bookmark: second)
        model._testPruneLUTDisplayNames()
    }
    #expect(model.selectedClipLUTName == "second.cube")
    #expect(model._testLUTDisplayNameCacheCount == 1)

    model.undo()
    #expect(model.selectedClipLUTName == "first.cube")
    #expect(model._testLUTDisplayNameCacheCount == 1)

    model.redo()
    #expect(model.selectedClipLUTName == "second.cube")
    #expect(model._testLUTDisplayNameCacheCount == 1)

    model.performUndoable("Remove LUT") {
        model.project.videoTracks.first!.clips[0].effects =
            model.project.videoTracks.first!.clips[0].effects.removingLUT()
        model._testPruneLUTDisplayNames()
    }
    #expect(model.selectedClipLUTName == nil)
    #expect(model._testLUTDisplayNameCacheCount == 0)

    model.undo()
    #expect(model.selectedClipLUTName == "second.cube")
    #expect(model._testLUTDisplayNameCacheCount == 1)
}

@MainActor
@Test("LUT-only clips are treated as exportable look presets")
func lutOnlyClipHasExportableLookPreset() {
    let model = EditorModel()
    let media = MediaItem(url: URL(filePath: "/dev/null"))
    model.project.mediaItems.append(media)
    let lutBookmark = Data([0xC0, 0xDE])
    var clip = Clip(mediaID: media.id,
                    sourceStart: .zero,
                    duration: CMTime(seconds: 5, preferredTimescale: 600),
                    timelineStart: .zero)
    clip.effects = [.lut(bookmark: lutBookmark)]
    model.project.videoTracks.first!.clips = [clip]
    model.selectedClipID = clip.id

    #expect(model.selectedClipHasLookEffects)
}

@Test("Look preset LUT resolver rejects unsafe sidecar paths")
func lookPresetLUTResolverRejectsUnsafePaths() throws {
    let tmp = URL(filePath: NSTemporaryDirectory())
        .appendingPathComponent("look-lut-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let presetURL = tmp.appendingPathComponent("look.lclook")
    try Data("{}".utf8).write(to: presetURL, options: .atomic)
    let unsafe = LookPresetLUTReference(relativePath: "../evil.cube", displayName: "evil.cube")

    #expect(EditorModel.resolvePresetLUT(unsafe, sourceURL: presetURL) == nil)
    #expect(!EditorModel.isSafeLookPresetLUTPath("assets/../evil.cube"))
    #expect(!EditorModel.isSafeLookPresetLUTPath("assets/luts/not-a-lut.png"))
    #expect(EditorModel.isSafeLookPresetLUTPath("assets/luts/look.cube"))
}

@Test("Clip has empty effects by default")
func clipDefaultEffects() {
    let clip = Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600), timelineStart: .zero)
    #expect(clip.effects.isEmpty)
}

@Test("Effect.colourGrade identity is neutral")
func colourGradeEffectIdentity() {
    let effect = Effect.colourGrade(.neutral)
    guard case .colourGrade(let grade) = effect else {
        Issue.record("Expected .colourGrade effect")
        return
    }
    #expect(grade.exposure == 0)
    #expect(grade.contrast == 1)
}

// MARK: - Identity pass-through tests

struct IdentityPassThroughCase: Sendable, CustomTestStringConvertible {
    let scenarioDescription: String
    let effects: [Effect]
    let size: CGSize
    let samplePoint: CGPoint
    let tolerance: Double
    var testDescription: String { scenarioDescription }
    var description: String { scenarioDescription }
}

@Test("EffectCompositor identity pass-through (R5.1)",
      arguments: [
        IdentityPassThroughCase(
            scenarioDescription: "empty chain",
            effects: [],
            size: CGSize(width: 16, height: 16),
            samplePoint: CGPoint(x: 8, y: 8),
            tolerance: 0
        ),
        IdentityPassThroughCase(
            scenarioDescription: "neutral colour grade",
            effects: [.colourGrade(.neutral)],
            size: CGSize(width: 16, height: 16),
            samplePoint: CGPoint(x: 8, y: 8),
            tolerance: 0.005
        ),
        IdentityPassThroughCase(
            scenarioDescription: "neutral look effects (halation+vignette+grain)",
            effects: [.halation(.neutral), .vignette(.neutral), .grain(.neutral)],
            size: CGSize(width: 32, height: 32),
            samplePoint: CGPoint(x: 16, y: 16),
            tolerance: 0.005
        ),
      ])
@MainActor
func identityPassThrough(testCase: IdentityPassThroughCase) {
    let compositor = EffectCompositor()
    let source = CIImage(color: CIColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: testCase.size.width, height: testCase.size.height))
    let result = compositor.applyEffectChain(source, effects: testCase.effects, cacheKey: nil)
    #expect(result.extent == source.extent, "\(testCase.description): extent mismatch")
    #expect(samplePixelEquals(result, source, at: testCase.samplePoint, tolerance: testCase.tolerance),
            "\(testCase.description): pixel mismatch")
}

@Test("EffectCompositor.applyEffectChain: grain cadence can advance independently of source time")
@MainActor
func grainCadenceUsesOutputFrameTime() throws {
    let compositor = EffectCompositor()
    let source = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    let grain = GrainEffect(amount: Keyframed(defaultValue: 0.7),
                            size: 1,
                            monochrome: true,
                            seed: 42)
    let sourceLocalTime = CMTime(seconds: 1, preferredTimescale: 600)

    let first = compositor.applyEffectChain(
        source,
        effects: [.grain(grain)],
        cacheKey: nil,
        at: sourceLocalTime,
        grainCadenceTime: CMTime(seconds: 2, preferredTimescale: 600),
        frameRate: 30)
    let next = compositor.applyEffectChain(
        source,
        effects: [.grain(grain)],
        cacheKey: nil,
        at: sourceLocalTime,
        grainCadenceTime: CMTime(seconds: 2 + 1.0 / 30.0, preferredTimescale: 600),
        frameRate: 30)

    let firstBytes = try #require(rgbaBytes(first, width: 32, height: 32))
    let nextBytes = try #require(rgbaBytes(next, width: 32, height: 32))
    #expect(firstBytes != nextBytes)
}

@Test("EffectCompositor.applyEffectChain: active vignette changes edge pixels")
@MainActor
func activeVignetteChangesEdgePixels() {
    let compositor = EffectCompositor()
    let source = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let result = compositor.applyEffectChain(
        source,
        effects: [.vignette(VignetteEffect(amount: Keyframed(defaultValue: 0.8),
                                           radius: 0.35,
                                           softness: 0.4))],
        cacheKey: nil)
    #expect(!samplePixelEquals(result, source, at: CGPoint(x: 2, y: 2), tolerance: 0.02))
}

@Test("EffectCompositor.applyEffectChain: negative vignette lifts edge pixels")
@MainActor
func negativeVignetteLiftsEdgePixels() throws {
    let compositor = EffectCompositor()
    let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let result = compositor.applyEffectChain(
        source,
        effects: [.vignette(VignetteEffect(amount: Keyframed(defaultValue: -0.8),
                                           radius: 0.35,
                                           softness: 0.4))],
        cacheKey: nil)

    let original = try #require(sampleRGBA(source, at: CGPoint(x: 2, y: 2)))
    let lifted = try #require(sampleRGBA(result, at: CGPoint(x: 2, y: 2)))
    #expect(lifted[0] > original[0])
    #expect(lifted[1] > original[1])
    #expect(lifted[2] > original[2])
}

@Test("Built-in look presets render deterministic snapshots")
@MainActor
func builtInLookPresetSnapshots() throws {
    let compositor = EffectCompositor()
    let source = CIImage(color: CIColor(red: 0.52, green: 0.48, blue: 0.42, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let sourceBytes = try #require(rgbaBytes(source, width: 64, height: 64))

    #expect(LookPresetLibrary.builtInPresets.count >= 10)
    for preset in LookPresetLibrary.builtInPresets {
        let first = compositor.applyEffectChain(
            source, effects: preset.effects, cacheKey: nil,
            at: CMTime(seconds: 0.25, preferredTimescale: 600))
        let second = compositor.applyEffectChain(
            source, effects: preset.effects, cacheKey: nil,
            at: CMTime(seconds: 0.25, preferredTimescale: 600))
        let firstBytes = try #require(rgbaBytes(first, width: 64, height: 64))
        let secondBytes = try #require(rgbaBytes(second, width: 64, height: 64))

        #expect(firstBytes == secondBytes, "\(preset.name) should render deterministically")
        #expect(firstBytes != sourceBytes, "\(preset.name) should change the fixture image")
    }
}

@Test("Built-in look preset resources match the in-memory library")
func builtInLookPresetResourcesMatchLibrary() throws {
    let root = try #require(Bundle.main.resourceURL)
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    let urls = (enumerator?.compactMap { $0 as? URL } ?? [])
        .filter { $0.pathExtension == LookPresetV1.fileExtension }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let resourcePresets = try urls.map { try LookPresetV1(data: Data(contentsOf: $0)) }
    let libraryByName = Dictionary(uniqueKeysWithValues: LookPresetLibrary.builtInPresets.map { ($0.name, $0) })

    #expect(resourcePresets.count == LookPresetLibrary.builtInPresets.count)
    #expect(Set(resourcePresets.map(\.name)) == Set(libraryByName.keys))
    for preset in resourcePresets {
        #expect(preset == libraryByName[preset.name], "\(preset.name) resource should match LookPresetLibrary")
    }
}

@Test("Exported look presets copy LUTs under assets/luts")
@MainActor
func exportedLookPresetCopiesLUTUnderAssetsLuts() async throws {
    let tmp = URL(filePath: NSTemporaryDirectory())
        .appendingPathComponent("look-preset-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let lutURL = tmp.appendingPathComponent("warm.cube")
    let lutData = Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
    try lutData.write(to: lutURL, options: .atomic)
    let lutBookmark = try lutURL.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil)

    let model = EditorModel()
    let clip = Clip(mediaID: UUID(),
                    sourceStart: .zero,
                    duration: CMTime(seconds: 2, preferredTimescale: 600),
                    timelineStart: .zero,
                    effects: [
                        .grain(GrainEffect(amount: Keyframed(defaultValue: 0.2))),
                        .lut(bookmark: lutBookmark),
                    ])
    model.project.videoTracks.first!.clips = [clip]
    model.selectedClipID = clip.id
    model._testCacheLUTDisplayName("warm.cube", for: lutBookmark)

    let presetURL = tmp.appendingPathComponent("Warm Look.lclook")
    let copiedLUT = tmp.appendingPathComponent("assets/luts/Warm Look.cube")
    model.exportLookPreset(to: presetURL)
    for _ in 0..<300 {
        if FileManager.default.fileExists(atPath: presetURL.path),
           FileManager.default.fileExists(atPath: copiedLUT.path) {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    let preset = try LookPresetV1(data: Data(contentsOf: presetURL))
    #expect(preset.lut?.relativePath == "assets/luts/Warm Look.cube")
    #expect(try Data(contentsOf: copiedLUT) == lutData)
}

/// Renders `a` and `b` to single-pixel CGImages at `point` and compares the
/// RGBA bytes. Used by the colour-grading pass-through tests; lives near the
/// top of the file so multiple tests can share it.
@MainActor
private func samplePixelEquals(_ a: CIImage, _ b: CIImage, at point: CGPoint,
                               tolerance: Double = 0) -> Bool {
    let context = CIContext(options: nil)
    let one = CGRect(x: point.x, y: point.y, width: 1, height: 1)
    guard let ca = context.createCGImage(a, from: one),
          let cb = context.createCGImage(b, from: one),
          let pa = ca.dataProvider?.data, let pb = cb.dataProvider?.data,
          let ba = CFDataGetBytePtr(pa), let bb = CFDataGetBytePtr(pb) else { return false }
    let n = min(CFDataGetLength(pa), CFDataGetLength(pb))
    for i in 0..<n {
        let diff = abs(Double(ba[i]) - Double(bb[i])) / 255.0
        if diff > tolerance { return false }
    }
    return true
}

@MainActor
private func sampleRGBA(_ image: CIImage, at point: CGPoint) -> [UInt8]? {
    let context = CIContext(options: nil)
    let one = CGRect(x: point.x, y: point.y, width: 1, height: 1)
    guard let cgImage = context.createCGImage(image, from: one),
          let data = cgImage.dataProvider?.data,
          let pointer = CFDataGetBytePtr(data),
          CFDataGetLength(data) >= 4 else { return nil }
    return Array(UnsafeBufferPointer(start: pointer, count: 4))
}

@MainActor
private func rgbaBytes(_ image: CIImage, width: Int, height: Int) -> [UInt8]? {
    let context = CIContext(options: nil)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    context.render(image,
                   toBitmap: &bytes,
                   rowBytes: width * 4,
                   bounds: CGRect(x: 0, y: 0, width: width, height: height),
                   format: .RGBA8,
                   colorSpace: colorSpace)
    return bytes
}

// MARK: - Reset-preservation tests

struct ResetPreservationCase: Sendable, CustomTestStringConvertible {
    let scenarioDescription: String
    let initialEffects: [Effect]
    let resetMethod: ResetMethod
    let expectedPresent: [Effect]
    let expectedAbsent: [Effect]
    var testDescription: String { scenarioDescription }
    var description: String { scenarioDescription }

    enum ResetMethod: Sendable {
        case colour
        case looks
    }
}

@Test("Reset preserves non-target effects",
      arguments: [
        ResetPreservationCase(
            scenarioDescription: "resetClipColourEffects removes colour + LUT, keeps others",
            initialEffects: [
                .colourGrade(ColourGrade()),
                .skinSmooth(SkinSmoothEffect()),
                .grain(GrainEffect(amount: Keyframed(defaultValue: 0.2))),
                .halation(HalationEffect(strength: Keyframed(defaultValue: 0.2))),
                .vignette(VignetteEffect(amount: Keyframed(defaultValue: 0.2))),
                .lut(bookmark: Data([0x1])),
            ],
            resetMethod: .colour,
            expectedPresent: [
                .skinSmooth(SkinSmoothEffect()),
                .grain(GrainEffect(amount: Keyframed(defaultValue: 0.2))),
                .halation(HalationEffect(strength: Keyframed(defaultValue: 0.2))),
                .vignette(VignetteEffect(amount: Keyframed(defaultValue: 0.2))),
            ],
            expectedAbsent: [
                .colourGrade(ColourGrade()),
                .lut(bookmark: Data([0x1])),
            ]
        ),
        ResetPreservationCase(
            scenarioDescription: "resetClipLooks removes look effects, keeps colour + LUT + skin-smooth",
            initialEffects: [
                .colourGrade(ColourGrade(exposure: 0.2,
                                         contrast: 1.1,
                                         saturation: 0.9,
                                         temperatureOffset: 50,
                                         tintOffset: 5)),
                .lut(bookmark: Data([0x1])),
                .skinSmooth(SkinSmoothEffect()),
                .grain(GrainEffect(amount: Keyframed(defaultValue: 0.2))),
                .halation(HalationEffect(strength: Keyframed(defaultValue: 0.2))),
                .vignette(VignetteEffect(amount: Keyframed(defaultValue: 0.2))),
            ],
            resetMethod: .looks,
            expectedPresent: [
                .colourGrade(ColourGrade(exposure: 0.2,
                                         contrast: 1.1,
                                         saturation: 0.9,
                                         temperatureOffset: 50,
                                         tintOffset: 5)),
                .lut(bookmark: Data([0x1])),
                .skinSmooth(SkinSmoothEffect()),
            ],
            expectedAbsent: [
                .grain(GrainEffect(amount: Keyframed(defaultValue: 0.2))),
                .halation(HalationEffect(strength: Keyframed(defaultValue: 0.2))),
                .vignette(VignetteEffect(amount: Keyframed(defaultValue: 0.2))),
            ]
        ),
      ])
@MainActor
func resetPreservesNonTargetEffects(scenario: ResetPreservationCase) {
    let model = EditorModel()
    let clip = Clip(
        mediaID: UUID(),
        sourceStart: .zero,
        duration: CMTime(seconds: 5, preferredTimescale: 600),
        timelineStart: .zero)
    var effected = clip
    effected.effects = scenario.initialEffects
    model.project.videoTracks.first!.clips = [effected]
    model.selectedClipID = effected.id

    switch scenario.resetMethod {
    case .colour:
        model.resetClipColourEffects()
    case .looks:
        model.resetClipLooks()
    }

    let remaining = model.project.videoTracks.first!.clips.first!.effects

    // Effects that should survive the reset
    for expected in scenario.expectedPresent {
        let matches = remaining.contains { $0 == expected }
        #expect(matches, "\(scenario.description): expected \(expected) to be preserved")
    }

    // Effects that should be removed by the reset
    for absent in scenario.expectedAbsent {
        let matches = remaining.contains { $0 == absent }
        #expect(!matches, "\(scenario.description): expected \(absent) to be removed")
    }
}

@Test("Effect.lut stores bookmark data")
func lutEffectStoresData() {
    let data = Data([0x01, 0x02, 0x03])
    let effect = Effect.lut(bookmark: data)
    guard case .lut(bookmark: let stored) = effect else {
        Issue.record("Expected .lut effect")
        return
    }
    #expect(stored == data)
}

@Test("Effect.grain stores effect")
func grainEffectStores() {
    let effect = Effect.grain(GrainEffect(amount: Keyframed(defaultValue: 0.25)))
    guard case .grain(let grain) = effect else {
        Issue.record("Expected .grain effect")
        return
    }
    #expect(grain.amount.defaultValue == 0.25)
}
