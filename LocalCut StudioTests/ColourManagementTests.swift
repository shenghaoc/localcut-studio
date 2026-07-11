import Testing
import Foundation
import CoreVideo
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import AVFoundation
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - R6.1 — working-space change purges caption raster cache
//
// Serialized because every test in this file touches the process-wide
// `EffectCompositor.sharedCaptionRasterer` or `ScopeSampler.shared`; running
// them in parallel would race on shared singletons.

@MainActor
@Suite("Colour management", .serialized)
struct ColourManagementSerialTests {

    @Test("Project defaults to sRGB working space")
    func defaultWorkingSpaceIsSRGB() {
        let model = EditorModel()
        #expect(model.project.workingColourSpace == .sRGB)
    }

    @Test("setWorkingColourSpace purges the shared caption raster cache")
    func workingSpaceChangePurgesRasterCache() {
        // Seed the shared cache with one entry, then flip the working space and
        // verify the cache is empty — the `TitleRasterer.purge()` seam fired.
        EffectCompositor.purgeCaptionRasterCache()
        let line = CaptionLine(
            range: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            text: "Hello",
            words: nil,
            style: nil)
        EffectCompositor._testPopulateCaptionRasterCache(
            line: line, style: .identity, renderSize: CGSize(width: 320, height: 180))
        #expect(EffectCompositor.captionRasterCacheCount > 0)

        let model = EditorModel()
        model.setWorkingColourSpace(.displayP3)
        #expect(model.project.workingColourSpace == .displayP3)
        #expect(EffectCompositor.captionRasterCacheCount == 0)
    }

    @Test("setWorkingColourSpace is a no-op when the value is unchanged")
    func workingSpaceUnchangedIsNoop() {
        let model = EditorModel()
        let beforeCount = EffectCompositor.captionRasterCacheCount
        model.setWorkingColourSpace(model.project.workingColourSpace)
        // Cache unchanged, no undo registered for a no-op.
        #expect(EffectCompositor.captionRasterCacheCount == beforeCount)
        #expect(model.canUndo == false)
    }

    private func seedRaster() {
        let line = CaptionLine(
            range: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            text: "Hello", words: nil, style: nil)
        EffectCompositor._testPopulateCaptionRasterCache(
            line: line, style: .identity, renderSize: CGSize(width: 320, height: 180))
    }

    @Test("setRenderSize purges the shared caption raster cache")
    func renderSizeChangePurgesRasterCache() {
        EffectCompositor.purgeCaptionRasterCache()
        seedRaster()
        #expect(EffectCompositor.captionRasterCacheCount > 0)

        let model = EditorModel()
        model.setRenderSize(CGSize(width: 1280, height: 720))
        #expect(EffectCompositor.captionRasterCacheCount == 0)
    }

    @Test("Undo of a resolution change purges the caption raster cache (applyState path)")
    func resolutionUndoPurgesRasterCache() {
        let model = EditorModel()
        let original = model.project.renderSize
        model.setRenderSize(CGSize(width: 1280, height: 720))

        // Repopulate after the change, then undo back to the original size —
        // applyState must purge even though it bypasses setRenderSize.
        EffectCompositor.purgeCaptionRasterCache()
        seedRaster()
        #expect(EffectCompositor.captionRasterCacheCount > 0)

        model.undo()
        #expect(model.project.renderSize == original)
        #expect(EffectCompositor.captionRasterCacheCount == 0)
    }
}

// MARK: - R6.2 — pixel buffer carries colour-space attachments

@Suite("Colour management — pixel buffers + scopes")
struct ColourManagementValueTests {

struct ColourAttachmentCase: Sendable, CustomTestStringConvertible {
    let space: WorkingColourSpace
    let expectedPrimaries: String
    let expectedTransfer: String
    let expectedMatrix: String
    let transferMustDifferFrom: String?
    var testDescription: String { "\(space)" }
}

@Test("applyColourAttachments tags pixel buffer correctly", arguments: [
    ColourAttachmentCase(space: .sRGB,
                         expectedPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                         expectedTransfer: kCVImageBufferTransferFunction_sRGB as String,
                         expectedMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                         transferMustDifferFrom: nil),
    ColourAttachmentCase(space: .displayP3,
                         expectedPrimaries: kCVImageBufferColorPrimaries_P3_D65 as String,
                         expectedTransfer: kCVImageBufferTransferFunction_sRGB as String,
                         expectedMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                         transferMustDifferFrom: nil),
    ColourAttachmentCase(space: .rec709,
                         expectedPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                         expectedTransfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                         expectedMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                         transferMustDifferFrom: kCVImageBufferTransferFunction_sRGB as String),
    ColourAttachmentCase(space: .rec2020,
                         expectedPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                         expectedTransfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                         expectedMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                         transferMustDifferFrom: nil),
])
func pixelBufferColourAttachments(_ cs: ColourAttachmentCase) {
    guard let buffer = makePixelBuffer(width: 64, height: 36) else {
        Issue.record("Could not allocate test pixel buffer")
        return
    }
    EffectCompositor.applyColourAttachments(cs.space, to: buffer)
    let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
    let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
    let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
    #expect(primaries == cs.expectedPrimaries)
    #expect(transfer == cs.expectedTransfer)
    #expect(matrix == cs.expectedMatrix)
    if let differ = cs.transferMustDifferFrom {
        #expect(transfer != differ)
    }
}

// MARK: - R6.3 — scope sampler waveform is non-empty for a non-black frame

@Test("ScopeSampler waveform has non-empty bins for a non-black frame")
func waveformSamplesNonBlackFrame() {
    let context = EffectCompositor.context(for: .sRGB)
    let colorSpace = WorkingColourSpace.sRGB.cgColorSpace
    // A 64×64 mid-grey CIImage — every column should report luma > 0.
    let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))

    let sample = ScopeSampler.shared.sample(image: image, context: context, colorSpace: colorSpace)
    #expect(!sample.waveform.isEmpty)
    let anyColumn = sample.waveform.contains { $0.hasContent }
    #expect(anyColumn)
    // The vectorscope now plots one bounded-readback point per pixel, not an
    // 8×8 cell-average proxy.
    #expect(sample.vectorscope.count == 64 * 64)
}

@Test("ScopeSampler waveform separates dark and bright columns from one readback")
func waveformSingleReadbackSeparatesColumns() {
    let context = EffectCompositor.context(for: .sRGB)
    let colorSpace = WorkingColourSpace.sRGB.cgColorSpace
    let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
    let black = CIImage(color: .black).cropped(to: bounds)
    let whiteRight = CIImage(color: .white)
        .cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
    let image = whiteRight.composited(over: black)

    let sample = ScopeSampler.shared.sample(image: image, context: context, colorSpace: colorSpace)
    let firstColumn = sample.waveform.first
    let lastColumn = sample.waveform.last

    #expect((firstColumn?.bins.first ?? 0) > 0.9)
    #expect((lastColumn?.bins.last ?? 0) > 0.9)
}

// MARK: - Persistence round-trip

@Test("ProjectDocument round-trips a non-default working colour space")
func documentRoundTripsWorkingSpace() throws {
    let project = Project()
    project.workingColourSpace = .rec709
    let document = ProjectDocument(project: project)
    let encoded = try document.encoded()
    let decoded = try ProjectDocument(data: encoded)
    #expect(decoded.workingColourSpace == .rec709)
}

@Test("Legacy document without workingColourSpace decodes as sRGB")
func legacyDocumentDecodesAsSRGB() throws {
    // A minimal v2 document body — no `workingColourSpace` key.
    let json = """
    {
      "schemaVersion": 2,
      "name": "Untitled",
      "renderWidth": 1920,
      "renderHeight": 1080,
      "frameRate": 30,
      "media": [],
      "videoTracks": [],
      "audioTracks": [],
      "captionTracks": []
    }
    """
    let data = Data(json.utf8)
    let decoded = try ProjectDocument(data: data)
    #expect(decoded.workingColourSpace == .sRGB)
}

@Test("Unknown workingColourSpace value falls back to sRGB instead of throwing")
func unknownWorkingSpaceDecodesAsSRGB() throws {
    // A document from a hypothetical future schema with a wider-gamut case.
    // The open path must not fail outright — the `schemaVersion > current`
    // guard then runs and the user gets a safe fallback.
    let json = """
    {
      "schemaVersion": 99,
      "workingColourSpace": "futureSpace",
      "renderWidth": 1920,
      "renderHeight": 1080,
      "frameRate": 30,
      "media": [],
      "videoTracks": [],
      "audioTracks": []
    }
    """
    let decoded = try ProjectDocument(data: Data(json.utf8))
    #expect(decoded.workingColourSpace == .sRGB)
}

}

// MARK: - Sampler gate (serialized — touches ScopeSampler.shared)

@Suite("Colour management — sampler gate", .serialized)
struct ScopeSamplerGateTests {

    @Test("ScopeSampler shouldSample short-circuits when disabled")
    func samplerGateRespectsEnabled() {
        ScopeSampler.shared.setEnabled(false)
        #expect(ScopeSampler.shared.shouldSample() == false)
    }

    @Test("ScopeSampler gate honours the 30 Hz cap")
    func samplerGateThrottles() {
        ScopeSampler.shared.setEnabled(true)

        let now: TimeInterval = 1000
        #expect(ScopeSampler.shared.shouldSample(now: now) == true)
        #expect(ScopeSampler.shared.shouldSample(now: now + 0.001) == false)
        #expect(ScopeSampler.shared.shouldSample(now: now + 1) == true)

        // Reset lastSampleAt to 0 so Xcode's "run test repeatedly" feature
        // does not see a stale timestamp from the prior run.
        _ = ScopeSampler.shared.shouldSample(now: 0)
        // Restore disabled-by-default so peer tests don't see a hot sampler.
        ScopeSampler.shared.setEnabled(false)
    }

    @Test("ScopeSampler.publish drops out-of-order samples")
    func samplerDropsStaleSamples() {
        ScopeSampler.shared.setEnabled(false)
        // Two samples, the second older than the first by `generatedAt`.
        let newer = ScopeSample(waveform: [], vectorscope: [],
                                generatedAt: Date(timeIntervalSince1970: 2000))
        let older = ScopeSample(waveform: [], vectorscope: [],
                                generatedAt: Date(timeIntervalSince1970: 1000))

        ScopeSampler.shared.publish(newer)
        let revisionAfterNewer = ScopeSampler.shared.snapshot.revision

        ScopeSampler.shared.publish(older)
        let snapshot = ScopeSampler.shared.snapshot
        // Older arrival should not overwrite the newer sample and should not
        // bump the revision.
        #expect(snapshot.sample?.generatedAt == newer.generatedAt)
        #expect(snapshot.revision == revisionAfterNewer)
    }

    @Test("ScopeSampler disabling clears the sample and bumps the revision")
    func samplerDisablePublishesClearRevision() {
        ScopeSampler.shared.setEnabled(false)
        let sample = ScopeSample(waveform: [], vectorscope: [],
                                 generatedAt: Date(timeIntervalSince1970: 3000))
        ScopeSampler.shared.publish(sample)
        let populated = ScopeSampler.shared.snapshot

        ScopeSampler.shared.setEnabled(false)
        let cleared = ScopeSampler.shared.snapshot

        #expect(populated.sample?.generatedAt == sample.generatedAt)
        #expect(cleared.sample == nil)
        #expect(cleared.revision == populated.revision &+ 1)
    }
}

// MARK: - Helpers

private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        attrs as CFDictionary, &buffer)
    return status == kCVReturnSuccess ? buffer : nil
}
