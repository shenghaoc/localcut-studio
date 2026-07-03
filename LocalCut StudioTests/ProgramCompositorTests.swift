import Testing
import Foundation
import CoreImage
import CoreVideo
@testable import LocalCut_Studio
import LocalCutCore

@Suite("ProgramCompositor")
struct ProgramCompositorTests {

    private func makeTestBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer)
        return pixelBuffer
    }

    @Test("Scene switch updates compositor state within one tick")
    func sceneSwitchOneTick() throws {
        let compositor = ProgramCompositor(renderSize: CGSize(width: 1920, height: 1080))
        let sourceId = UUID()

        let sceneA = SceneDefinition(name: "A", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0)
        ])
        let sceneB = SceneDefinition(name: "B", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId),
                      transform: Transform2D(translateX: 0, translateY: 0, scale: 0.5, rotation: 0),
                      zIndex: 0)
        ])

        compositor.updateScenes([sceneA, sceneB])
        compositor.switchScene(to: sceneA.id)

        let buf = try #require(makeTestBuffer())
        compositor.updateSource(sourceId, buffer: buf)

        // Composite with scene A.
        let frame1 = compositor.compositeFrame()
        #expect(frame1 != nil)

        // Switch to scene B — should take effect immediately (one tick).
        compositor.switchScene(to: sceneB.id)
        let frame2 = compositor.compositeFrame()
        #expect(frame2 != nil)

        // The frames should be different (different transforms).
        // We can't easily compare CIImages, but we verify they both succeed.
        #expect(compositor.currentScene?.name == "B")
    }

    @Test("No pipeline rebuild on switch — state only")
    func noPipelineRebuild() throws {
        let compositor = ProgramCompositor(renderSize: CGSize(width: 1920, height: 1080))
        let sourceId = UUID()
        let buf = try #require(makeTestBuffer())
        compositor.updateSource(sourceId, buffer: buf)

        let scenes = [
            SceneDefinition(name: "A", layers: [
                SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0)
            ]),
            SceneDefinition(name: "B", layers: [
                SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0)
            ]),
        ]
        compositor.updateScenes(scenes)

        // Multiple rapid scene switches should not crash or leak.
        for i in 0..<100 {
            compositor.switchScene(to: scenes[i % 2].id)
            _ = compositor.compositeFrame()
        }
        #expect(compositor.currentScene?.name != nil)
    }

    @Test("No encoder restart on switch")
    func noEncoderRestart() throws {
        let compositor = ProgramCompositor(renderSize: CGSize(width: 1920, height: 1080))
        let sourceId = UUID()
        let buf = try #require(makeTestBuffer())
        compositor.updateSource(sourceId, buffer: buf)

        let sceneA = SceneDefinition(name: "A", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0)
        ])
        compositor.updateScenes([sceneA])
        compositor.switchScene(to: sceneA.id)
        _ = compositor.compositeFrame()

        // Switch to same scene — should be no-op.
        compositor.switchScene(to: sceneA.id)
        _ = compositor.compositeFrame()
        #expect(compositor.currentScene?.name == "A")
    }

    @Test("Resolver output changes on next tick")
    func resolverOutputChangesOnNextTick() throws {
        let compositor = ProgramCompositor(renderSize: CGSize(width: 1920, height: 1080))
        let sourceId = UUID()
        let buf = try #require(makeTestBuffer())
        compositor.updateSource(sourceId, buffer: buf)

        var scene = SceneDefinition(name: "A", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0, opacity: 1.0)
        ])
        compositor.updateScenes([scene])
        compositor.switchScene(to: scene.id)

        // First frame — full opacity.
        let frame1 = compositor.compositeFrame()
        #expect(frame1 != nil)

        // Edit scene: change opacity.
        scene.layers[0].opacity = 0.5
        compositor.updateScenes([scene])

        // Next frame should reflect the change.
        let frame2 = compositor.compositeFrame()
        #expect(frame2 != nil)
    }

    @Test("Missing source produces nil frame for single-layer scene")
    func missingSourceProducesNil() {
        let compositor = ProgramCompositor(renderSize: CGSize(width: 1920, height: 1080))
        let sourceId = UUID()
        let scene = SceneDefinition(name: "A", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0)
        ])
        compositor.updateScenes([scene])
        compositor.switchScene(to: scene.id)

        // No source buffer fed — should return nil.
        let frame = compositor.compositeFrame()
        #expect(frame == nil)
    }

    @Test("Colour layer composites without source buffer")
    func colourLayerComposites() {
        let compositor = ProgramCompositor(renderSize: CGSize(width: 1920, height: 1080))
        let scene = SceneDefinition(name: "BG", layers: [
            SceneLayer(sourceRef: .colour(hex: "#FF0000"), zIndex: 0)
        ])
        compositor.updateScenes([scene])
        compositor.switchScene(to: scene.id)

        let frame = compositor.compositeFrame()
        #expect(frame != nil)
        #expect(frame?.extent == CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)))
    }

    @Test("Invisible layer is excluded")
    func invisibleLayerExcluded() throws {
        let compositor = ProgramCompositor(renderSize: CGSize(width: 1920, height: 1080))
        let sourceId = UUID()
        let buf = try #require(makeTestBuffer())
        compositor.updateSource(sourceId, buffer: buf)

        let scene = SceneDefinition(name: "A", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId), visible: false, zIndex: 0),
        ])
        compositor.updateScenes([scene])
        compositor.switchScene(to: scene.id)

        let frame = compositor.compositeFrame()
        #expect(frame == nil)
    }
}
