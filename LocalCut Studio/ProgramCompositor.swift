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
final class ProgramCompositor: @unchecked Sendable {

    /// The render canvas size (matches the project's render size).
    let renderSize: CGSize

    /// The Metal-backed CIContext used for compositing. Shared with the
    /// existing EffectCompositor's cache when possible.
    private let ciContext: CIContext

    /// Per-source latest pixel buffer. Updated by `LiveComposeTap.feed()`.
    private var sourceBuffers: [UUID: CVPixelBuffer] = [:]
    private let lock = NSLock()

    /// The current scene definition being composited.
    private var _currentScene: SceneDefinition?
    private var _scenes: [SceneDefinition] = []

    /// Transition state: when non-nil, we're lerping opacity over 200ms.
    private var _transitionStartTime: Date?
    private let transitionDuration: TimeInterval = 0.2

    init(renderSize: CGSize) {
        self.renderSize = renderSize
        // Create a Metal-backed CIContext matching the existing compositor's
        // approach (EffectCompositor uses per-colour-space cached contexts).
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }
    }

    /// Updates the source buffer for a given source. Called by
    /// LiveComposeTap when a new frame arrives.
    func updateSource(_ sourceID: UUID, buffer: CVPixelBuffer) {
        lock.lock()
        sourceBuffers[sourceID] = buffer
        lock.unlock()
    }

    /// Removes a source's buffer (on source disconnect).
    func removeSource(_ sourceID: UUID) {
        lock.lock()
        sourceBuffers.removeValue(forKey: sourceID)
        lock.unlock()
    }

    /// Sets the current scene. Called when the user switches scenes.
    /// Triggers a transition if `enableTransitions` is true.
    func switchScene(to sceneId: UUID, enableTransitions: Bool = false) {
        lock.lock()
        let newScene = _scenes.first(where: { $0.id == sceneId })
        let changed = _currentScene?.id != sceneId
        _currentScene = newScene
        if changed && enableTransitions {
            _transitionStartTime = Date()
        } else if changed {
            _transitionStartTime = nil
        }
        lock.unlock()
    }

    /// Updates the full scene list (called when scenes are edited).
    func updateScenes(_ scenes: [SceneDefinition]) {
        lock.lock()
        _scenes = scenes
        // If the current scene was edited, refresh it.
        if let currentId = _currentScene?.id {
            _currentScene = scenes.first(where: { $0.id == currentId })
        }
        lock.unlock()
    }

    /// The current scene being composited.
    var currentScene: SceneDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return _currentScene
    }

    /// Composites one output frame from the current scene's layers.
    /// Returns a `CIImage` representing the composited frame, or nil if
    /// no layers are visible.
    ///
    /// This is called once per compositor tick. The caller renders the
    /// returned `CIImage` into a `CVPixelBuffer` via `ciContext.render()`.
    func compositeFrame() -> CIImage? {
        lock.lock()
        let scene = _currentScene
        let buffers = sourceBuffers
        let transitionStart = _transitionStartTime
        lock.unlock()

        guard let scene else { return nil }

        // Compute transition opacity factor (0…1).
        let transitionAlpha: Float
        if let start = transitionStart {
            let elapsed = Date().timeIntervalSince(start)
            let progress = min(elapsed / transitionDuration, 1.0)
            // Ease-out cubic.
            let t = 1.0 - pow(1.0 - progress, 3)
            transitionAlpha = Float(t)
        } else {
            transitionAlpha = 1.0
        }

        // Resolve layers: filter visible, sort by z-index.
        let layers = scene.layers
            .filter { $0.visible }
            .sorted { $0.zIndex < $1.zIndex }

        guard !layers.isEmpty else { return nil }

        // Composite bottom-to-top.
        var composite: CIImage?
        for layer in layers {
            guard let buffer = buffers[layerSourceId(layer)] else {
                // Source not available — skip this layer.
                continue
            }
            let ciImage = CIImage(cvPixelBuffer: buffer)
            let transformed = applyLayerTransform(
                ciImage: ciImage,
                layer: layer,
                canvasSize: renderSize,
                transitionAlpha: transitionAlpha)
            if let existing = composite {
                composite = transformed.compositingOverImage(existing)
            } else {
                composite = transformed
            }
        }

        return composite
    }

    /// Renders the composited frame into a `CVPixelBuffer`. Returns the
    /// rendered buffer, or nil if compositing produced no output.
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

    /// Extracts the source ID from a scene layer for buffer lookup.
    private func layerSourceId(_ layer: SceneLayer) -> UUID {
        switch layer.sourceRef {
        case .captureSource(let id): id
        case .still(let id): id
        case .colour: UUID() // Colour layers don't have a source buffer.
        }
    }

    /// Applies a layer's transform and opacity to a CIImage.
    private func applyLayerTransform(ciImage: CIImage,
                                     layer: SceneLayer,
                                     canvasSize: CGSize,
                                     transitionAlpha: Float) -> CIImage {
        let layerW = ciImage.extent.width
        let layerH = ciImage.extent.height
        let canvasW = canvasSize.width
        let canvasH = canvasSize.height

        // Scale to fit canvas (fill, preserving aspect).
        let scaleX = canvasW / layerW
        let scaleY = canvasH / layerH
        let scale = max(scaleX, scaleY)
        let scaledW = layerW * scale
        let scaledH = layerH * scale

        // Centre on canvas.
        let tx = (canvasW - scaledW) / 2
        let ty = (canvasH - scaledH) / 2

        var t = CGAffineTransform.identity
        t = t.translatedBy(x: tx, y: ty)
        t = t.scaledBy(x: scale, y: scale)

        // Apply the layer's normalised transform (centre-origin).
        let lt = layer.transform.cgTransform
        // Translate to centre, apply layer transform, translate back.
        let centreT = CGAffineTransform(translationX: canvasW / 2, y: canvasH / 2)
        let invCentreT = centreT.inverted()
        t = t.concatenating(invCentreT).concatenating(lt).concatenating(centreT)

        var result = ciImage.transformed(by: t)

        // Apply opacity (including transition alpha).
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
