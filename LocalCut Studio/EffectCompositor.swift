import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreVideo

// MARK: - Layer metadata for the compositor

struct CompositorLayer {
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let opacity: Float
    let effects: [Effect]
}

// MARK: - Custom instruction

final class EffectCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [CompositorLayer]

    init(timeRange: CMTimeRange, layers: [CompositorLayer]) {
        self.timeRange = timeRange
        self.layers = layers
        requiredSourceTrackIDs = layers.isEmpty ? [] : layers.map { NSNumber(value: $0.trackID) as NSValue }
    }
}

// MARK: - Custom video compositor

final class EffectCompositor: NSObject, AVVideoCompositing {

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let sharedCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: sRGBColorSpace])
        }
        return CIContext(options: [.workingColorSpace: sRGBColorSpace])
    }()

    nonisolated var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    }

    nonisolated var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    nonisolated func renderContextChanged(_: AVVideoCompositionRenderContext) {}

    nonisolated func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? EffectCompositionInstruction else {
            request.finish(with: AVError(.invalidVideoComposition))
            return
        }

        let renderSize = request.renderContext.size
        var result: CIImage?

        for layer in instruction.layers {
            guard let sourceBuffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }

            var image = CIImage(cvPixelBuffer: sourceBuffer)

            image = applyEffectChain(image, effects: layer.effects)

            image = image.transformed(by: layer.transform)

            if layer.opacity < 1 {
                let opacityFilter = CIFilter.colorMatrix()
                opacityFilter.inputImage = image
                opacityFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity))
                image = opacityFilter.outputImage ?? image
            }

            if let existing = result {
                result = image.composited(over: existing)
            } else {
                result = image
            }
        }

        guard let destination = request.renderContext.newPixelBuffer() else {
            request.finish(with: AVError(.invalidVideoComposition))
            return
        }

        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))
        let composited = result?.composited(over: black) ?? black

        let destinationRect = CGRect(origin: .zero, size: renderSize)
        Self.sharedCIContext.render(composited, to: destination, bounds: destinationRect, colorSpace: Self.sRGBColorSpace)

        request.finish(withComposedVideoFrame: destination)
    }

    // MARK: - Effect chain

    nonisolated private func applyEffectChain(_ image: CIImage, effects: [Effect]) -> CIImage {
        var result = image
        for effect in effects {
            switch effect {
            case .colourGrade(let grade):
                result = applyColourGrade(result, grade: grade)
            case .lut(bookmark: let data):
                result = applyLUT(result, bookmarkData: data) ?? result
            }
        }
        return result
    }

    nonisolated private func applyColourGrade(_ image: CIImage, grade: ColourGrade) -> CIImage {
        var result = image

        if grade.exposure != 0 {
            if let output = outputImage(named: "CIExposureAdjust", configure: { filter in
                filter.setValue(result, forKey: kCIInputImageKey)
                filter.setValue(grade.exposure, forKey: "inputEV")
            }) {
                result = output
            }
        }

        if grade.contrast != 1 || grade.saturation != 1 {
            if let output = outputImage(named: "CIColorControls", configure: { filter in
                filter.setValue(result, forKey: kCIInputImageKey)
                filter.setValue(grade.contrast, forKey: "inputContrast")
                filter.setValue(grade.saturation, forKey: "inputSaturation")
            }) {
                result = output
            }
        }

        if grade.temperatureOffset != 0 || grade.tintOffset != 0 {
            if let output = outputImage(named: "CITemperatureAndTint", configure: { filter in
                filter.setValue(result, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                filter.setValue(CIVector(x: 6500 + CGFloat(grade.temperatureOffset), y: CGFloat(grade.tintOffset)), forKey: "inputTargetNeutral")
            }) {
                result = output
            }
        }

        return result
    }

    nonisolated private func applyLUT(_ image: CIImage, bookmarkData: Data) -> CIImage? {
        if let cached = LUTCache.shared.lut(forBookmark: bookmarkData) {
            return colorCube(image: image, dimension: cached.dimension, cubeData: cached.cubeData)
        }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                 options: [.withSecurityScope, .withoutUI],
                                 bookmarkDataIsStale: &isStale),
              !isStale else { return nil }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let lutData = try? Data(contentsOf: url),
              let result = CubeLUTParser.parse(lutData) else { return nil }

        let floats = result.table
        let cubeData = Data(bytes: floats, count: floats.count * MemoryLayout<Float>.stride)
        let cached = CachedLUT(dimension: result.dimension, cubeData: cubeData)
        LUTCache.shared.setLut(cached, forBookmark: bookmarkData)

        return colorCube(image: image, dimension: cached.dimension, cubeData: cached.cubeData)
    }

    nonisolated private func colorCube(image: CIImage, dimension: Int, cubeData: Data) -> CIImage? {
        outputImage(named: "CIColorCubeWithColorSpace", configure: { filter in
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(Float(dimension), forKey: "inputCubeDimension")
            filter.setValue(cubeData, forKey: "inputCubeData")
            filter.setValue(Self.sRGBColorSpace, forKey: "inputColorSpace")
        })
    }

    nonisolated private func outputImage(named name: String, configure: (CIFilter) -> Void) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setDefaults()
        configure(filter)
        return filter.outputImage
    }
}

// MARK: - LUT cache

private struct CachedLUT: Sendable {
    let dimension: Int
    let cubeData: Data
}

private final class LUTCache: @unchecked Sendable {
    nonisolated static let shared = LUTCache()
    private let lock = NSLock()
    nonisolated(unsafe) private var cache: [Data: CachedLUT] = [:]

    nonisolated func lut(forBookmark bookmark: Data) -> CachedLUT? {
        lock.lock()
        defer { lock.unlock() }
        return cache[bookmark]
    }

    nonisolated func setLut(_ lut: CachedLUT, forBookmark bookmark: Data) {
        lock.lock()
        defer { lock.unlock() }
        cache[bookmark] = lut
    }
}

// MARK: - .cube LUT parser

private struct CubeLUTResult {
    let dimension: Int
    let table: [Float]
}

private enum CubeLUTParser {

    nonisolated static func parse(_ data: Data) -> CubeLUTResult? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        var dimension = 0
        var entries: [[Float]] = []

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") { continue }

            let parts = trimmed.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !parts.isEmpty else { continue }

            if parts[0] == "LUT_3D_SIZE", parts.count >= 2 {
                dimension = Int(parts[1]) ?? 0
                continue
            }

            guard let r = Float(parts[0]) else { continue }
            if parts.count >= 3, let g = Float(parts[1]), let b = Float(parts[2]) {
                entries.append([r, g, b])
            }
        }

        guard dimension > 1,
              entries.count == dimension * dimension * dimension else { return nil }

        var table = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        for i in 0..<entries.count {
            let entry = entries[i]
            table[i * 4 + 0] = entry[0]
            table[i * 4 + 1] = entry[1]
            table[i * 4 + 2] = entry[2]
            table[i * 4 + 3] = 1.0
        }

        return CubeLUTResult(dimension: dimension, table: table)
    }
}
