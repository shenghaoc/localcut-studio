import Foundation
import CoreImage
import CoreVideo
import Metal
import LocalCutCore

// MARK: - ProgramCompositor

/// Wraps the existing Metal-backed `CIContext` to composite live capture
/// sources into a single program output frame. Uses the same rendering
/// pipeline as the timeline preview — no parallel architecture.
///
/// Scene switches update only the current scene state; no pipeline rebuild,
/// no texture reallocation, no encoder restart.
nonisolated final class ProgramCompositor: @unchecked Sendable {

    /// The render canvas size (matches the project's render size).
    let renderSize: CGSize

    /// The Metal-backed CIContext used for compositing.
    private let ciContext: CIContext

    /// Per-source latest pixel buffer.
    private var sourceBuffers: [UUID: CVPixelBuffer] = [:]

    /// The current scene definition being composited.
    private(set) var currentScene: SceneDefinition?
    private var scenes: [SceneDefinition] = []

    /// Transition state: when non-nil, we're lerping opacity over 200ms.
    private var transitionStartTime: Date?
    private let transitionDuration: TimeInterval = 0.2

    nonisolated init(renderSize: CGSize) {
        self.renderSize = renderSize
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }
    }

    /// Updates the source buffer for a given source.
    func updateSource(_ sourceID: UUID, buffer: CVPixelBuffer) {
        sourceBuffers[sourceID] = buffer
    }

    /// Removes a source's buffer (on source disconnect).
    func removeSource(_ sourceID: UUID) {
        sourceBuffers.removeValue(forKey: sourceID)
    }

    /// Sets the current scene. Called when the user switches scenes.
    func switchScene(to sceneId: UUID, enableTransitions: Bool = false) {
        let newScene = scenes.first(where: { $0.id == sceneId })
        let changed = currentScene?.id != sceneId
        currentScene = newScene
        if changed && enableTransitions {
            transitionStartTime = Date()
        } else if changed {
            transitionStartTime = nil
        }
    }

    /// Updates the full scene list (called when scenes are edited).
    func updateScenes(_ scenes: [SceneDefinition]) {
        self.scenes = scenes
        if let currentId = currentScene?.id {
            currentScene = scenes.first(where: { $0.id == currentId })
        }
    }

    /// Composites one output frame from the current scene's layers.
    func compositeFrame() -> CIImage? {
        guard let scene = currentScene else { return nil }

        let transitionAlpha: Float
        if let start = transitionStartTime {
            let elapsed = Date().timeIntervalSince(start)
            let progress = min(elapsed / transitionDuration, 1.0)
            let t = 1.0 - pow(1.0 - progress, 3)
            transitionAlpha = Float(t)
            if progress >= 1.0 {
                transitionStartTime = nil
            }
        } else {
            transitionAlpha = 1.0
        }

        let layers = scene.layers
            .filter { $0.visible }
            .sorted { $0.zIndex < $1.zIndex }

        guard !layers.isEmpty else { return nil }

        var composite: CIImage?
        for layer in layers {
            let ciImage: CIImage
            switch layer.sourceRef {
            case .captureSource(let id), .still(let id):
                guard let buffer = sourceBuffers[id] else { continue }
                ciImage = CIImage(cvPixelBuffer: buffer)
            case .colour(let hex):
                ciImage = colourImage(hex: hex)
            }
            let transformed = applyLayerTransform(
                ciImage: ciImage,
                layer: layer,
                canvasSize: renderSize,
                transitionAlpha: transitionAlpha)
            if let existing = composite {
                composite = transformed.composited(over: existing)
            } else {
                composite = transformed
            }
        }

        return composite
    }

    /// Renders the composited frame into a `CVPixelBuffer`.
    func renderFrame() -> CVPixelBuffer? {
        guard let composited = compositeFrame() else { return nil }

        let width = Int(renderSize.width)
        let height = Int(renderSize.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer)
        guard status == kCVReturnSuccess, let output = pixelBuffer else { return nil }

        ciContext.render(composited, to: output)
        return output
    }

    // MARK: - Private

    private func applyLayerTransform(ciImage: CIImage,
                                     layer: SceneLayer,
                                     canvasSize: CGSize,
                                     transitionAlpha: Float) -> CIImage {
        let extent = ciImage.extent.isInfinite
            ? CGRect(origin: .zero, size: canvasSize)
            : ciImage.extent
        let layerW = extent.width
        let layerH = extent.height
        let canvasW = canvasSize.width
        let canvasH = canvasSize.height

        let scaleX = canvasW / layerW
        let scaleY = canvasH / layerH
        let scale = max(scaleX, scaleY)
        let scaledW = layerW * scale
        let scaledH = layerH * scale

        let tx = (canvasW - scaledW) / 2
        let ty = (canvasH - scaledH) / 2

        var t = CGAffineTransform.identity
        t = t.translatedBy(x: tx, y: ty)
        t = t.scaledBy(x: scale, y: scale)

        let lt = layer.transform.cgTransform
        let centreT = CGAffineTransform(translationX: canvasW / 2, y: canvasH / 2)
        let invCentreT = centreT.inverted()
        t = t.concatenating(invCentreT).concatenating(lt).concatenating(centreT)

        var result = ciImage.transformed(by: t)

        let opacity = layer.opacity * transitionAlpha
        if opacity < 1.0 {
            let alphaFilter = CIFilter.colorMatrix()
            alphaFilter.inputImage = result
            alphaFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
            if let filtered = alphaFilter.outputImage {
                result = filtered
            }
        }

        return result
    }

    private func colourImage(hex: String) -> CIImage {
        CIImage(color: ciColor(hex: hex))
            .cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    private func ciColor(hex: String) -> CIColor {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6 || trimmed.count == 8,
              let value = UInt64(trimmed, radix: 16) else {
            return CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if trimmed.count == 8 {
            red = CGFloat((value >> 24) & 0xff) / 255
            green = CGFloat((value >> 16) & 0xff) / 255
            blue = CGFloat((value >> 8) & 0xff) / 255
            alpha = CGFloat(value & 0xff) / 255
        } else {
            red = CGFloat((value >> 16) & 0xff) / 255
            green = CGFloat((value >> 8) & 0xff) / 255
            blue = CGFloat(value & 0xff) / 255
            alpha = 1
        }
        return CIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
