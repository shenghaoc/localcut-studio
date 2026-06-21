import Foundation
import AVFoundation
import CoreImage
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

final class EffectCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = false
    let requiredSourceTrackIDs: [NSValue]? = nil
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [CompositorLayer]

    init(timeRange: CMTimeRange, layers: [CompositorLayer]) {
        self.timeRange = timeRange
        self.layers = layers
    }
}

// MARK: - Custom video compositor

final class EffectCompositor: NSObject, AVVideoCompositing {

    private static let sharedCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    }()

    nonisolated var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    }

    nonisolated var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    nonisolated(unsafe) private var renderContext: AVVideoCompositionRenderContext?

    nonisolated func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

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
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity))
                ])
            }

            if let existing = result {
                result = image.composited(over: existing)
            } else {
                result = image
            }
        }

        guard let composited = result,
              let destination = request.renderContext.newPixelBuffer() else {
            request.finish(with: AVError(.invalidVideoComposition))
            return
        }

        let destinationRect = CGRect(origin: .zero, size: renderSize)
        Self.sharedCIContext.render(composited, to: destination, bounds: destinationRect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

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
            guard let filter = CIFilter(name: "CIExposureAdjust") else { return result }
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(grade.exposure, forKey: "inputEV")
            if let output = filter.outputImage { result = output }
        }

        if grade.contrast != 1 || grade.saturation != 1 {
            guard let filter = CIFilter(name: "CIColorControls") else { return result }
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(grade.contrast, forKey: "inputContrast")
            filter.setValue(grade.saturation, forKey: "inputSaturation")
            if let output = filter.outputImage { result = output }
        }

        if grade.temperatureOffset != 0 || grade.tintOffset != 0 {
            guard let filter = CIFilter(name: "CITemperatureAndTint") else { return result }
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500 + CGFloat(grade.temperatureOffset), y: CGFloat(grade.tintOffset)), forKey: "inputTargetNeutral")
            if let output = filter.outputImage { result = output }
        }

        return result
    }

    nonisolated private func applyLUT(_ image: CIImage, bookmarkData: Data) -> CIImage? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, bookmarkDataIsStale: &isStale),
              !isStale,
              url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let lutData = try? Data(contentsOf: url) else { return nil }
        guard let result = CubeLUTParser.parse(lutData) else { return nil }

        let dim = result.dimension
        let floats = result.table
        let cubeData = Data(bytes: floats, count: floats.count * MemoryLayout<Float>.stride)

        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Float(dim), forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return filter.outputImage
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

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)

            if parts[0] == "LUT_3D_SIZE", parts.count >= 2 {
                dimension = Int(parts[1]) ?? 0
                continue
            }

            if parts.count >= 3 {
                let rgb = parts.compactMap { Float($0) }
                if rgb.count == 3 {
                    entries.append(rgb)
                }
            }
        }

        guard dimension > 1,
              entries.count == dimension * dimension * dimension else { return nil }

        var table = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var idx = 0
        for r in 0..<dimension {
            for g in 0..<dimension {
                for b in 0..<dimension {
                    let entry = entries[idx]
                    table[(r * dimension * dimension + g * dimension + b) * 4 + 0] = entry[0]
                    table[(r * dimension * dimension + g * dimension + b) * 4 + 1] = entry[1]
                    table[(r * dimension * dimension + g * dimension + b) * 4 + 2] = entry[2]
                    table[(r * dimension * dimension + g * dimension + b) * 4 + 3] = 1.0
                    idx += 1
                }
            }
        }

        return CubeLUTResult(dimension: dimension, table: table)
    }
}
