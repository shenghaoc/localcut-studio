import Foundation
import CoreMedia
import CoreGraphics

/// Generates zoom-n-pan keyframe sets from presets, enforcing velocity and
/// acceleration bounds to prevent jarring motion.
public enum ZoomPanPresetGenerator {
    /// Tolerance for floating-point comparison of keyframe times.
    private static let timeTolerance: Double = 0.001

    /// Generate keyframes for the given preset, clamped to the clip's duration.
    ///
    /// - Parameters:
    ///   - preset: The zoom-pan preset to apply.
    ///   - clipDuration: The clip's source duration.
    /// - Returns: An array of keyframes in clip-source-local time, sorted by time.
    public static func generateKeyframes(
        for preset: ZoomPanPreset,
        clipDuration: CMTime
    ) -> [Keyframe<Transform2D>] {
        let duration = min(preset.duration, clipDuration).seconds
        guard duration > 0 else { return [] }

        let keyframes: [Keyframe<Transform2D>]
        switch preset.kind {
        case .slowZoomIn:
            keyframes = slowZoomIn(
                targetPoint: preset.targetPoint,
                endScale: preset.endScale,
                duration: duration)
        case .pan:
            keyframes = pan(
                targetPoint: preset.targetPoint,
                endScale: preset.endScale,
                duration: duration)
        case .snapZoomOnClick:
            keyframes = snapZoomOnClick(
                targetPoint: preset.targetPoint,
                endScale: preset.endScale,
                duration: duration)
        }

        return enforceBounds(keyframes: keyframes, duration: duration)
    }

    // MARK: - Preset Implementations

    /// Slow zoom into a target point over the duration.
    private static func slowZoomIn(
        targetPoint: CGPoint,
        endScale: Float,
        duration: Double
    ) -> [Keyframe<Transform2D>] {
        // Translation points toward the centre (opposite sign of the target
        // offset) because the compositor applies translation before the
        // centre-relative scale-around-centre transform.
        let tx = Float(0.5 - targetPoint.x) * (endScale - 1)
        let ty = Float(0.5 - targetPoint.y) * (endScale - 1)

        let start = Keyframe<Transform2D>(
            time: CMTime(seconds: 0, preferredTimescale: 600),
            value: .identity)
        let end = Keyframe<Transform2D>(
            time: CMTime(seconds: duration, preferredTimescale: 600),
            value: Transform2D(translateX: tx, translateY: ty,
                               scale: endScale, rotation: 0))
        return [start, end]
    }

    /// Horizontal pan across the frame at a fixed scale.
    private static func pan(
        targetPoint: CGPoint,
        endScale: Float,
        duration: Double
    ) -> [Keyframe<Transform2D>] {
        let baseTx = Float(0.5 - targetPoint.x) * (endScale - 1)
        let startTx = baseTx - 0.3
        let endTx = baseTx + 0.3
        let ty = Float(0.5 - targetPoint.y) * (endScale - 1)

        let start = Keyframe<Transform2D>(
            time: CMTime(seconds: 0, preferredTimescale: 600),
            value: Transform2D(translateX: startTx, translateY: ty,
                               scale: endScale, rotation: 0))
        let end = Keyframe<Transform2D>(
            time: CMTime(seconds: duration, preferredTimescale: 600),
            value: Transform2D(translateX: endTx, translateY: ty,
                               scale: endScale, rotation: 0))
        return [start, end]
    }

    /// Quick zoom to a point, hold, then zoom back out.
    private static func snapZoomOnClick(
        targetPoint: CGPoint,
        endScale: Float,
        duration: Double
    ) -> [Keyframe<Transform2D>] {
        let zoomInTime = min(0.3, duration * 0.15)
        let holdTime = duration * 0.7

        let tx = Float(0.5 - targetPoint.x) * (endScale - 1)
        let ty = Float(0.5 - targetPoint.y) * (endScale - 1)
        let zoomed = Transform2D(translateX: tx, translateY: ty,
                                 scale: endScale, rotation: 0)

        return [
            Keyframe(time: CMTime(seconds: 0, preferredTimescale: 600),
                     value: .identity),
            Keyframe(time: CMTime(seconds: zoomInTime, preferredTimescale: 600),
                     value: zoomed),
            Keyframe(time: CMTime(seconds: holdTime, preferredTimescale: 600),
                     value: zoomed),
            Keyframe(time: CMTime(seconds: duration, preferredTimescale: 600),
                     value: .identity),
        ]
    }

    // MARK: - Bounds Enforcement

    /// Enforce velocity and acceleration bounds on the keyframes.
    ///
    /// If any segment violates bounds, the keyframes are adjusted to cap the
    /// velocity/acceleration while preserving the overall shape as much as possible.
    /// Public so `AutoZoomProposalGenerator` can also enforce bounds on its output.
    static func enforceBounds(
        keyframes: [Keyframe<Transform2D>],
        duration: Double
    ) -> [Keyframe<Transform2D>] {
        guard keyframes.count >= 2 else { return keyframes }

        var result = keyframes
        for i in 1..<result.count {
            let dt = result[i].time.seconds - result[i - 1].time.seconds
            guard dt > 0 else { continue }

            let prev = result[i - 1].value
            let curr = result[i].value
            // Use a mutable copy so translation and scale clamping compose
            // correctly when both exceed bounds in the same segment.
            var updatedValue = curr

            // Check translation velocity
            let dx = curr.tx - prev.tx
            let dy = curr.ty - prev.ty
            let dist = sqrt(dx * dx + dy * dy)
            let velocity = dist * ZoomPanBounds.referenceRenderWidth / Float(dt)

            if velocity > ZoomPanBounds.maxVelocity {
                let velocityScale = ZoomPanBounds.maxVelocity / velocity
                updatedValue.tx = prev.tx + dx * velocityScale
                updatedValue.ty = prev.ty + dy * velocityScale
            }

            // Check scale velocity (operates on the already-clamped value)
            let currentScale = updatedValue.decomposedScale
            let scaleDelta = abs(currentScale - prev.decomposedScale)
            let scaleVelocity = scaleDelta / Float(dt)
            if scaleVelocity > ZoomPanBounds.maxScaleVelocity, currentScale > 0 {
                let scaleFactor = ZoomPanBounds.maxScaleVelocity / scaleVelocity
                let targetScale = prev.decomposedScale + (currentScale - prev.decomposedScale) * scaleFactor
                let ratio = targetScale / currentScale
                updatedValue = Transform2D(a: updatedValue.a * ratio, b: updatedValue.b * ratio,
                                           c: updatedValue.c * ratio, d: updatedValue.d * ratio,
                                           tx: updatedValue.tx, ty: updatedValue.ty)
            }

            if updatedValue != curr {
                result[i] = Keyframe<Transform2D>(
                    id: result[i].id,
                    time: result[i].time,
                    value: updatedValue,
                    incomingHandle: result[i].incomingHandle,
                    outgoingHandle: result[i].outgoingHandle)
            }
        }

        // Check acceleration bounds (rate of change of velocity between segments)
        if result.count >= 3 {
            for i in 1..<(result.count - 1) {
                let dt1 = result[i].time.seconds - result[i - 1].time.seconds
                let dt2 = result[i + 1].time.seconds - result[i].time.seconds
                guard dt1 > 0, dt2 > 0 else { continue }

                let v1 = translationVelocity(from: result[i - 1].value, to: result[i].value, dt: Float(dt1))
                let v2 = translationVelocity(from: result[i].value, to: result[i + 1].value, dt: Float(dt2))
                let avgDt = Float((dt1 + dt2) / 2)
                let acceleration = abs(v2 - v1) / avgDt

                if acceleration > ZoomPanBounds.maxAcceleration {
                    // Reduce the second segment's velocity to cap acceleration
                    let maxV2 = v1 + ZoomPanBounds.maxAcceleration * avgDt * (v2 > v1 ? 1 : -1)
                    let ratio = abs(maxV2 / max(0.001, v2))
                    if ratio < 1 {
                        let prev = result[i].value
                        let curr = result[i + 1].value
                        let dx = curr.tx - prev.tx
                        let dy = curr.ty - prev.ty
                        let newTx = prev.tx + dx * ratio
                        let newTy = prev.ty + dy * ratio
                        result[i + 1] = Keyframe<Transform2D>(
                            id: result[i + 1].id,
                            time: result[i + 1].time,
                            value: Transform2D(a: curr.a, b: curr.b, c: curr.c,
                                               d: curr.d, tx: newTx, ty: newTy),
                            incomingHandle: result[i + 1].incomingHandle,
                            outgoingHandle: result[i + 1].outgoingHandle)
                    }
                }
            }
        }

        // Restore the last keyframe to identity when the original preset
        // requested it. This is a design choice (e.g. snap zoom ends at
        // identity), not a velocity violation. The velocity bounds are
        // meant for intermediate keyframes, not the final identity.
        if keyframes.last?.value == .identity, let last = result.last {
            result[result.count - 1] = Keyframe<Transform2D>(
                id: last.id,
                time: last.time,
                value: .identity,
                incomingHandle: last.incomingHandle,
                outgoingHandle: last.outgoingHandle)
        }

        return result
    }

    private static func translationVelocity(
        from a: Transform2D,
        to b: Transform2D,
        dt: Float
    ) -> Float {
        let dx = b.tx - a.tx
        let dy = b.ty - a.ty
        return sqrt(dx * dx + dy * dy) * ZoomPanBounds.referenceRenderWidth / max(0.001, dt)
    }
}
