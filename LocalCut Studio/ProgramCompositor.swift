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
@MainActor
final class ProgramCompositor {

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
        } else {
            transitionAlpha = 1.0
        }

        let layers = scene.layers
            .filter { $0.visible }
            .sorted { $0.zIndex < $1.zIndex }

        guard !layers.isEmpty else { return nil }

        var composite: CIImage?
        for layer in layers {
            guard let buffer = sourceBuffers[layerSourceId(layer)] else { continue }
            let ciImage = CIImage(cvPixelBuffer: buffer)
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

    private func layerSourceId(_ layer: SceneLayer) -> UUID {
        switch layer.sourceRef {
        case .captureSource(let id): id
        case .still(let id): id
        case .colour: UUID()
        }
    }

    private func applyLayerTransform(ciImage: CIImage,
                                     layer: SceneLayer,
                                     canvasSize: CGSize,
                                     transitionAlpha: Float) -> CIImage {
        let layerW = ciImage.extent.width
        let layerH = ciImage.extent.height
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
}
