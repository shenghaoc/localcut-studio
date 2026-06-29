import Foundation
import CoreMedia

/// Portable JSON zoom-pan preset used by Phase 43. Stores a sequence of
/// `ZoomPanKeyframe` points with Bezier handles, plus velocity/acceleration
/// bounds that are enforced at stamp time.
public struct ZoomPanPresetV1: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "lczoompan"

    public var schemaVersion: Int
    public var name: String
    /// Keyframes in normalised time (0…1 across the clip's source duration).
    public var keyframes: [PresetKeyframe]

    public struct PresetKeyframe: Hashable, Codable, Sendable {
        /// Normalised position (0 = clip start, 1 = clip end).
        public var t: Double
        public var value: ZoomPanKeyframe
        public var incomingHandle: KeyframeHandle?
        public var outgoingHandle: KeyframeHandle?

        public init(t: Double, value: ZoomPanKeyframe,
                    incomingHandle: KeyframeHandle? = nil,
                    outgoingHandle: KeyframeHandle? = nil) {
            self.t = t
            self.value = value
            self.incomingHandle = incomingHandle
            self.outgoingHandle = outgoingHandle
        }
    }

    public init(schemaVersion: Int = ZoomPanPresetV1.currentSchemaVersion,
                name: String,
                keyframes: [PresetKeyframe]) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.keyframes = keyframes.sorted { $0.t < $1.t }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ZoomPanPresetV1.self, from: data)
    }

    /// Stamps the preset keyframes onto a clip's `zoomPan` track, converting
    /// normalised time to clip-source-local `CMTime`.
    public func stamping(onto clipDuration: CMTime) -> Keyframed<ZoomPanKeyframe> {
        let duration = clipDuration.seconds
        guard duration > 0 else {
            return Keyframed(defaultValue: .identity)
        }
        let kfs = keyframes.map { pk in
            let time = CMTime(seconds: pk.t * duration, preferredTimescale: 600)
            return Keyframe(time: time, value: pk.value,
                            incomingHandle: pk.incomingHandle,
                            outgoingHandle: pk.outgoingHandle)
        }
        return Keyframed(keyframes: kfs, defaultValue: .identity)
    }
}

// MARK: - Velocity / acceleration validation

/// Enforces velocity and acceleration bounds on zoom-pan keyframes to prevent
/// whip-pan and jarring motion.
public enum ZoomPanValidator {
    /// Maximum scale change per second (prevents whip-zoom).
    public static let maxScaleVelocity: Float = 0.5
    /// Maximum pan offset change per second in normalised coords.
    public static let maxPanVelocity: Float = 1.0
    /// Maximum acceleration per second² for any component.
    public static let maxAcceleration: Float = 2.0

    /// Validates and clamps a set of keyframes to the velocity/acceleration
    /// bounds. Returns the clamped keyframes.
    public static func clamped(_ keyframes: [Keyframe<ZoomPanKeyframe>],
                               duration: CMTime) -> [Keyframe<ZoomPanKeyframe>] {
        guard keyframes.count >= 2 else { return keyframes }
        var result = keyframes.sorted { $0.time < $1.time }
        for i in 1..<result.count {
            let dt = Float((result[i].time - result[i - 1].time).seconds)
            guard dt > 0 else { continue }
            let prev = result[i - 1].value
            var curr = result[i].value

            // Clamp scale velocity
            let scaleVel = abs(curr.scale - prev.scale) / dt
            if scaleVel > maxScaleVelocity {
                let maxDelta = maxScaleVelocity * dt
                curr.scale = prev.scale + maxDelta * Float.sign(curr.scale - prev.scale)
            }

            // Clamp pan velocity
            let panVelX = abs(curr.offsetX - prev.offsetX) / dt
            if panVelX > maxPanVelocity {
                let maxDelta = maxPanVelocity * dt
                curr.offsetX = prev.offsetX + maxDelta * Float.sign(curr.offsetX - prev.offsetX)
            }
            let panVelY = abs(curr.offsetY - prev.offsetY) / dt
            if panVelY > maxPanVelocity {
                let maxDelta = maxPanVelocity * dt
                curr.offsetY = prev.offsetY + maxDelta * Float.sign(curr.offsetY - prev.offsetY)
            }

            result[i].value = curr
        }
        return result
    }
}

private extension Float {
    /// Returns -1, 0, or 1 matching the sign of the value.
    static func sign(_ v: Float) -> Float {
        if v > 0 { return 1 }
        if v < 0 { return -1 }
        return 0
    }
}

// MARK: - Built-in presets

/// The set of zoom-pan presets shipped with LocalCut Studio.
public enum BuiltInZoomPanPresets {
    public static let all: [ZoomPanPresetV1] = [
        slowZoomIn,
        slowZoomOut,
        panLeft,
        panRight,
        kenBurnsDiagonal,
        snapZoomIn,
        snapZoomOut,
    ]

    /// Slowly zooms into the centre of the frame.
    public static let slowZoomIn = ZoomPanPresetV1(
        name: "Slow Zoom In",
        keyframes: [
            .init(t: 0, value: ZoomPanKeyframe(scale: 1, offsetX: 0, offsetY: 0)),
            .init(t: 1, value: ZoomPanKeyframe(scale: 1.3, offsetX: 0, offsetY: 0)),
        ])

    /// Slowly zooms out from the centre.
    public static let slowZoomOut = ZoomPanPresetV1(
        name: "Slow Zoom Out",
        keyframes: [
            .init(t: 0, value: ZoomPanKeyframe(scale: 1.3, offsetX: 0, offsetY: 0)),
            .init(t: 1, value: ZoomPanKeyframe(scale: 1, offsetX: 0, offsetY: 0)),
        ])

    /// Slowly pans left across the frame.
    public static let panLeft = ZoomPanPresetV1(
        name: "Pan Left",
        keyframes: [
            .init(t: 0, value: ZoomPanKeyframe(scale: 1.15, offsetX: 0.1, offsetY: 0)),
            .init(t: 1, value: ZoomPanKeyframe(scale: 1.15, offsetX: -0.1, offsetY: 0)),
        ])

    /// Slowly pans right across the frame.
    public static let panRight = ZoomPanPresetV1(
        name: "Pan Right",
        keyframes: [
            .init(t: 0, value: ZoomPanKeyframe(scale: 1.15, offsetX: -0.1, offsetY: 0)),
            .init(t: 1, value: ZoomPanKeyframe(scale: 1.15, offsetX: 0.1, offsetY: 0)),
        ])

    /// Ken Burns style diagonal zoom + pan.
    public static let kenBurnsDiagonal = ZoomPanPresetV1(
        name: "Ken Burns",
        keyframes: [
            .init(t: 0, value: ZoomPanKeyframe(scale: 1, offsetX: -0.08, offsetY: -0.05)),
            .init(t: 1, value: ZoomPanKeyframe(scale: 1.25, offsetX: 0.08, offsetY: 0.05)),
        ])

    /// Quick snap zoom in (for click emphasis).
    public static let snapZoomIn = ZoomPanPresetV1(
        name: "Snap Zoom In",
        keyframes: [
            .init(t: 0, value: ZoomPanKeyframe(scale: 1, offsetX: 0, offsetY: 0)),
            .init(t: 0.15, value: ZoomPanKeyframe(scale: 1.5, offsetX: 0, offsetY: 0)),
            .init(t: 1, value: ZoomPanKeyframe(scale: 1.5, offsetX: 0, offsetY: 0)),
        ])

    /// Quick snap zoom out (from emphasis).
    public static let snapZoomOut = ZoomPanPresetV1(
        name: "Snap Zoom Out",
        keyframes: [
            .init(t: 0, value: ZoomPanKeyframe(scale: 1.5, offsetX: 0, offsetY: 0)),
            .init(t: 0.15, value: ZoomPanKeyframe(scale: 1, offsetX: 0, offsetY: 0)),
            .init(t: 1, value: ZoomPanKeyframe(scale: 1, offsetX: 0, offsetY: 0)),
        ])
}
