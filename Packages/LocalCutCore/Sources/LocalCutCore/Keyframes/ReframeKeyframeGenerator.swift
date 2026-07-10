import Foundation
import CoreMedia

// MARK: - Reframe Keyframe Generator (Phase 33)

/// Generates bounded transform keyframes from a subject trajectory.
///
/// Enforces:
/// - Scale ≥ 1.0 (no letterbox)
/// - Velocity ≤ bound
/// - Acceleration ≤ bound
/// - Action-safe zone compliance ≥ 95% (via iterative scale increase)
public struct ReframeKeyframeGenerator: Sendable {
    /// Source media natural size (pixels).
    public let sourceSize: CGSize
    /// Target render size after aspect conversion (pixels).
    public let targetSize: CGSize
    /// Reframe options (bounds, safe-zone, etc.).
    public let options: ReframeOptions

    public init(sourceSize: CGSize, targetSize: CGSize, options: ReframeOptions) {
        self.sourceSize = sourceSize
        self.targetSize = targetSize
        self.options = options
    }

    // MARK: - Derived geometry

    /// The scale factor needed to aspect-fill the target into the source.
    /// Any keyframe scale must be ≥ this value to avoid letterbox.
    public var aspectFillScale: Float {
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else { return 1.0 }
        let sourceAspect = Float(sourceSize.width / sourceSize.height)
        let targetAspect = Float(targetSize.width / targetSize.height)
        if sourceAspect > targetAspect {
            // Source is wider: height-limited fill
            return targetAspect / sourceAspect
        } else {
            // Source is taller or equal: width-limited fill
            return sourceAspect / targetAspect
        }
    }

    /// Available pan bounds at a given scale (overscan headroom).
    /// At `scale = aspectFillScale`, panBound = 0 for the fill axis.
    public func panBounds(scale: Float) -> (x: Float, y: Float) {
        let fill = aspectFillScale
        guard fill > 0 else { return (x: 0, y: 0) }
        let overscanX = (scale / fill - 1.0) / 2.0
        let overscanY = (scale / fill - 1.0) / 2.0
        return (x: max(0, overscanX), y: max(0, overscanY))
    }

    // MARK: - Keyframe generation

    /// Generates transform keyframes from trajectory samples.
    ///
    /// - Parameters:
    ///   - samples: Tracked subject trajectory (sorted by time).
    ///   - clipDuration: Total clip source duration.
    /// - Returns: The reframe proposal with keyframes and warnings.
    public func generate(
        samples: [SubjectTrajectorySample],
        clipDuration: CMTime
    ) -> ReframeProposal {
        guard !samples.isEmpty, clipDuration > .zero else {
            return ReframeProposal()
        }

        var warnings: [ReframeWarning] = []

        // Very short clips: start + end only
        if clipDuration.seconds < options.analysisFPS * 2 {
            warnings.append(.veryShortClip(duration: clipDuration.seconds))
            return generateVeryShortKeyframes(samples: samples, clipDuration: clipDuration, warnings: warnings)
        }

        // Step 1: Generate raw keyframes from trajectory
        var rawKeyframes = generateRawKeyframes(from: samples)

        // Step 2: Iteratively enforce motion bounds
        rawKeyframes = enforceMotionBounds(rawKeyframes)

        // Step 3: Enforce safe-zone compliance
        let (finalKeyframes, safeWarnings) = enforceSafeZone(rawKeyframes)
        warnings.append(contentsOf: safeWarnings)

        return ReframeProposal(
            keyframes: finalKeyframes,
            detectionMode: .face, // caller fills this in
            framesAnalyzed: samples.count,
            warnings: warnings
        )
    }

    // MARK: - Raw keyframe generation

    private func generateRawKeyframes(from samples: [SubjectTrajectorySample]) -> [ReframeKeyframeProposal] {
        samples.map { sample in
            let scale = max(1.0, aspectFillScale)
            let bounds = panBounds(scale: scale)
            let tx = clamp(-sample.center.x * scale + 0.5, -bounds.x, bounds.x)
            let ty = clamp(-sample.center.y * scale + 0.5, -bounds.y, bounds.y)
            let transform = Transform2D(translateX: tx, translateY: ty, scale: scale, rotation: 0)
            return ReframeKeyframeProposal(time: sample.time, value: transform)
        }
    }

    // MARK: - Motion bounds

    /// Iteratively clamps velocity and acceleration until convergence.
    private func enforceMotionBounds(_ keyframes: [ReframeKeyframeProposal]) -> [ReframeKeyframeProposal] {
        guard keyframes.count >= 2 else { return keyframes }
        var result = keyframes
        let maxIterations = 20

        for _ in 0..<maxIterations {
            var changed = false

            // Enforce velocity bound
            for i in 1..<result.count {
                let dt = max(0.001, (result[i].time - result[i - 1].time).seconds)
                let dx = result[i].value.tx - result[i - 1].value.tx
                let dy = result[i].value.ty - result[i - 1].value.ty
                let speed = sqrt(dx * dx + dy * dy) / Float(dt)

                if speed > options.velocityBound {
                    let ratio = options.velocityBound / speed
                    let newTx = result[i - 1].value.tx + dx * ratio
                    let newTy = result[i - 1].value.ty + dy * ratio
                    result[i].value.tx = newTx
                    result[i].value.ty = newTy
                    changed = true
                }
            }

            // Enforce acceleration bound
            for i in 2..<result.count {
                let dt1 = max(0.001, (result[i - 1].time - result[i - 2].time).seconds)
                let dt2 = max(0.001, (result[i].time - result[i - 1].time).seconds)
                let v1x = (result[i - 1].value.tx - result[i - 2].value.tx) / Float(dt1)
                let v1y = (result[i - 1].value.ty - result[i - 2].value.ty) / Float(dt1)
                let v2x = (result[i].value.tx - result[i - 1].value.tx) / Float(dt2)
                let v2y = (result[i].value.ty - result[i - 1].value.ty) / Float(dt2)
                let ax = (v2x - v1x) / Float(dt2)
                let ay = (v2y - v1y) / Float(dt2)
                let accel = sqrt(ax * ax + ay * ay)

                if accel > options.accelerationBound {
                    let ratio = options.accelerationBound / accel
                    let targetVx = v1x + (v2x - v1x) * ratio
                    let targetVy = v1y + (v2y - v1y) * ratio
                    let newTx = result[i - 1].value.tx + targetVx * Float(dt2)
                    let newTy = result[i - 1].value.ty + targetVy * Float(dt2)
                    result[i].value.tx = newTx
                    result[i].value.ty = newTy
                    changed = true
                }
            }

            if !changed { break }
        }

        return result
    }

    // MARK: - Safe-zone compliance

    /// Ensures ≥ 95% of keyframes have their subject centre inside the
    /// action-safe region (centre ± halfExtent). If compliance is below
    /// threshold, increases scale by 1% iteratively up to 20%.
    private func enforceSafeZone(
        _ keyframes: [ReframeKeyframeProposal]
    ) -> ([ReframeKeyframeProposal], [ReframeWarning]) {
        guard !keyframes.isEmpty else { return (keyframes, []) }
        var warnings: [ReframeWarning] = []
        var result = keyframes
        let halfExtent = options.actionSafeHalfExtent
        let maxScaleIncrease: Float = 1.20 // up to 20% increase
        let minScaleCompliant: Float = 0.95

        var currentScale = max(1.0, aspectFillScale)
        let baseScale = currentScale

        for iteration in 0..<20 {
            let compliance = measureSafeZoneCompliance(result, halfExtent: halfExtent)
            if compliance >= minScaleCompliant {
                return (result, warnings)
            }

            // Increase scale by 1%
            let newScale = baseScale * (1.0 + Float(iteration + 1) * 0.01)
            guard newScale <= baseScale * maxScaleIncrease else {
                // Scale cap reached
                warnings.append(.safeZoneComplianceBelowThreshold(
                    compliance: compliance, scaleUsed: currentScale))
                break
            }
            currentScale = newScale

            // Regenerate keyframes with increased scale
            result = result.map { kf in
                rescaleKeyframe(kf, scale: currentScale)
            }
            // Re-enforce motion bounds after rescaling
            result = enforceMotionBounds(result)
        }

        return (result, warnings)
    }

    /// Measures what fraction of keyframes have the subject centre inside
    /// the action-safe region.
    private func measureSafeZoneCompliance(
        _ keyframes: [ReframeKeyframeProposal],
        halfExtent: Float
    ) -> Float {
        guard !keyframes.isEmpty else { return 1.0 }
        let compliant = keyframes.filter { kf in
            // Subject centre in the keyframe's local space
            let subjectCx = (0.5 - kf.value.tx) / max(0.001, kf.value.decomposedScale)
            let subjectCy = (0.5 - kf.value.ty) / max(0.001, kf.value.decomposedScale)
            return abs(subjectCx - 0.5) <= halfExtent
                && abs(subjectCy - 0.5) <= halfExtent
        }.count
        return Float(compliant) / Float(keyframes.count)
    }

    /// Rescales a keyframe to a new scale, clamping position to new bounds.
    private func rescaleKeyframe(_ kf: ReframeKeyframeProposal, scale: Float) -> ReframeKeyframeProposal {
        let bounds = panBounds(scale: scale)
        let subjectCx = (0.5 - kf.value.tx) / max(0.001, kf.value.decomposedScale)
        let subjectCy = (0.5 - kf.value.ty) / max(0.001, kf.value.decomposedScale)
        let tx = clamp(-subjectCx * scale + 0.5, -bounds.x, bounds.x)
        let ty = clamp(-subjectCy * scale + 0.5, -bounds.y, bounds.y)
        var result = kf
        result.value = Transform2D(translateX: tx, translateY: ty, scale: scale, rotation: 0)
        return result
    }

    // MARK: - Very short clips

    private func generateVeryShortKeyframes(
        samples: [SubjectTrajectorySample],
        clipDuration: CMTime,
        warnings: [ReframeWarning]
    ) -> ReframeProposal {
        guard let first = samples.first, let last = samples.last else {
            return ReframeProposal(warnings: warnings)
        }
        let scale = max(1.0, aspectFillScale)
        let bounds = panBounds(scale: scale)

        func makeTransform(_ sample: SubjectTrajectorySample) -> Transform2D {
            let tx = clamp(-sample.center.x * scale + 0.5, -bounds.x, bounds.x)
            let ty = clamp(-sample.center.y * scale + 0.5, -bounds.y, bounds.y)
            return Transform2D(translateX: tx, translateY: ty, scale: scale, rotation: 0)
        }

        var keyframes: [ReframeKeyframeProposal] = [
            ReframeKeyframeProposal(time: .zero, value: makeTransform(first))
        ]
        if last.time != .zero {
            keyframes.append(ReframeKeyframeProposal(time: clipDuration, value: makeTransform(last)))
        }

        return ReframeProposal(
            keyframes: keyframes,
            detectionMode: .face,
            framesAnalyzed: samples.count,
            warnings: warnings
        )
    }
}

// MARK: - Helpers

private func clamp(_ value: Float, _ minVal: Float, _ maxVal: Float) -> Float {
    min(maxVal, max(minVal, value))
}
