import SwiftUI
import AppKit
import AVFoundation
import LocalCutCore

private struct SpeedCurveGridCanvas: View, Equatable {
    let rect: CGRect
    /// Included so light/dark appearance changes invalidate the equatable canvas.
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, _ in
            // Touch colorScheme so appearance is a real input to this view.
            let _ = colorScheme
            let border = Path(roundedRect: rect, cornerRadius: 6)
            context.fill(border, with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.65)))
            context.stroke(border, with: .color(.secondary.opacity(0.28)), lineWidth: 1)

            for step in 1..<4 {
                let y = rect.minY + rect.height * CGFloat(step) / 4
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(path, with: .color(.secondary.opacity(0.16)), lineWidth: 0.5)
            }
        }
    }
}

private enum SpeedCurveDragTarget: Equatable {
    case defaultValue
    case keyframe(UUID)
    case incoming(UUID)
    case outgoing(UUID)
}

struct SpeedCurveEditor: View {
    let clip: Clip
    let frameRate: Double
    let onChange: (Keyframed<Float>) -> Void
    let onCommit: () -> Void
    let onReset: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragTarget: SpeedCurveDragTarget?

    private let inset: CGFloat = 10
    private let handleRadius: CGFloat = 4
    private let keyframeRadius: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpeedCurveGridCanvas(rect: plotRect(size: proxy.size), colorScheme: colorScheme)
                    .equatable()
                Canvas { context, size in
                    let plan = localSegmentPlan
                    let outputDuration = TimeRemapping.outputDuration(for: plan)
                    drawCurve(context: &context,
                              size: size,
                              plan: plan,
                              outputDuration: outputDuration)
                    drawHandles(context: &context,
                                size: size,
                                plan: plan,
                                outputDuration: outputDuration)
                    drawKeyframes(context: &context,
                                  size: size,
                                  plan: plan,
                                  outputDuration: outputDuration)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let target = dragTarget ?? nearestTarget(to: value.startLocation,
                                                                 size: proxy.size)
                        guard let target else { return }
                        dragTarget = target
                        update(target, at: value.location, size: proxy.size)
                    }
                    .onEnded { _ in
                        dragTarget = nil
                        onCommit()
                    }
            )
            .contextMenu {
                Button("Reset Speed Curve", role: .destructive) {
                    onReset()
                }
            }
        }
        .frame(minHeight: 124, idealHeight: 136)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed curve editor")
        .accessibilityValue(accessibilitySpeedValue)
        .accessibilityAdjustableAction { direction in
            // Allow VoiceOver users to adjust the default speed with swipe up/down.
            var curve = clip.speedCurve
            let step: Float = 0.25
            switch direction {
            case .increment:
                curve.defaultValue = TimeRemapping.clampedSpeed(curve.defaultValue + step)
            case .decrement:
                curve.defaultValue = TimeRemapping.clampedSpeed(curve.defaultValue - step)
            @unknown default:
                break
            }
            onChange(curve)
            onCommit()
        }
    }

    private var accessibilitySpeedValue: String {
        let keyframeCount = clip.speedCurve.keyframes.count
        let speed = String(format: "%.2f", clip.speedCurve.defaultValue)
        if keyframeCount == 0 {
            return "Constant speed \(speed)x"
        } else {
            return "\(keyframeCount) speed keyframes, base speed \(speed)x"
        }
    }

    private var localSegmentPlan: [TimeRemapSegment] {
        TimeRemapping.segmentPlan(sourceDuration: clip.duration, speedCurve: clip.speedCurve)
    }

    private func drawCurve(context: inout GraphicsContext,
                           size: CGSize,
                           plan: [TimeRemapSegment],
                           outputDuration: CMTime) {
        var path = Path()
        let samples = max(24, Int(size.width / 3))
        for index in 0...samples {
            let fraction = Double(index) / Double(samples)
            let sourceOffset = TimeRemapping.multiplied(clip.duration, by: fraction)
            let speed = TimeRemapping.speedValue(in: clip.speedCurve, at: sourceOffset)
            let point = point(sourceOffset: sourceOffset,
                              speed: speed,
                              size: size,
                              plan: plan,
                              outputDuration: outputDuration)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(.lcAccent), lineWidth: 2.5)
    }

    private func drawHandles(context: inout GraphicsContext,
                             size: CGSize,
                             plan: [TimeRemapSegment],
                             outputDuration: CMTime) {
        let keyframes = clip.speedCurve.keyframes
        guard keyframes.count > 1 else { return }

        for index in keyframes.indices {
            let keyframe = keyframes[index]
            let keyPoint = point(sourceOffset: keyframe.time,
                                 speed: keyframe.value,
                                 size: size,
                                 plan: plan,
                                 outputDuration: outputDuration)
            if index < keyframes.index(before: keyframes.endIndex) {
                let handle = outgoingHandle(for: keyframe, next: keyframes[index + 1])
                let handlePoint = outgoingPoint(handle,
                                                from: keyframe,
                                                to: keyframes[index + 1],
                                                size: size,
                                                plan: plan,
                                                outputDuration: outputDuration)
                drawHandleLine(context: &context, from: keyPoint, to: handlePoint)
                drawHandleDot(context: &context, at: handlePoint)
            }
            if index > keyframes.startIndex {
                let handle = incomingHandle(for: keyframe, previous: keyframes[index - 1])
                let handlePoint = incomingPoint(handle,
                                                from: keyframes[index - 1],
                                                to: keyframe,
                                                size: size,
                                                plan: plan,
                                                outputDuration: outputDuration)
                drawHandleLine(context: &context, from: keyPoint, to: handlePoint)
                drawHandleDot(context: &context, at: handlePoint)
            }
        }
    }

    private func drawHandleLine(context: inout GraphicsContext, from start: CGPoint, to end: CGPoint) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(.secondary.opacity(0.42)), lineWidth: 1)
    }

    private func drawHandleDot(context: inout GraphicsContext, at point: CGPoint) {
        let rect = CGRect(x: point.x - handleRadius, y: point.y - handleRadius,
                          width: handleRadius * 2, height: handleRadius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.8)))
    }

    private func drawKeyframes(context: inout GraphicsContext,
                               size: CGSize,
                               plan: [TimeRemapSegment],
                               outputDuration: CMTime) {
        let keyframes = clip.speedCurve.keyframes
        if keyframes.isEmpty {
            let point = point(sourceOffset: TimeRemapping.multiplied(clip.duration, by: 0.5),
                              speed: clip.speedCurve.defaultValue,
                              size: size,
                              plan: plan,
                              outputDuration: outputDuration)
            let rect = CGRect(x: point.x - keyframeRadius,
                              y: point.y - keyframeRadius,
                              width: keyframeRadius * 2,
                              height: keyframeRadius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.lcAccent))
            return
        }

        for keyframe in keyframes {
            let point = point(sourceOffset: keyframe.time,
                              speed: keyframe.value,
                              size: size,
                              plan: plan,
                              outputDuration: outputDuration)
            let rect = CGRect(x: point.x - keyframeRadius,
                              y: point.y - keyframeRadius,
                              width: keyframeRadius * 2,
                              height: keyframeRadius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.lcAccent))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
    }

    private func nearestTarget(to location: CGPoint, size: CGSize) -> SpeedCurveDragTarget? {
        let keyframes = clip.speedCurve.keyframes
        guard !keyframes.isEmpty else { return .defaultValue }

        let plan = localSegmentPlan
        let outputDuration = TimeRemapping.outputDuration(for: plan)
        var candidates: [(target: SpeedCurveDragTarget, distance: CGFloat)] = []
        for index in keyframes.indices {
            let keyframe = keyframes[index]
            let keyPoint = point(sourceOffset: keyframe.time,
                                 speed: keyframe.value,
                                 size: size,
                                 plan: plan,
                                 outputDuration: outputDuration)
            candidates.append((.keyframe(keyframe.id), distance(location, keyPoint)))
            if index < keyframes.index(before: keyframes.endIndex) {
                let handle = outgoingHandle(for: keyframe, next: keyframes[index + 1])
                let handlePoint = outgoingPoint(handle,
                                                from: keyframe,
                                                to: keyframes[index + 1],
                                                size: size,
                                                plan: plan,
                                                outputDuration: outputDuration)
                candidates.append((.outgoing(keyframe.id), distance(location, handlePoint)))
            }
            if index > keyframes.startIndex {
                let handle = incomingHandle(for: keyframe, previous: keyframes[index - 1])
                let handlePoint = incomingPoint(handle,
                                                from: keyframes[index - 1],
                                                to: keyframe,
                                                size: size,
                                                plan: plan,
                                                outputDuration: outputDuration)
                candidates.append((.incoming(keyframe.id), distance(location, handlePoint)))
            }
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }),
              best.distance <= 16 else { return nil }
        return best.target
    }

    private func update(_ target: SpeedCurveDragTarget, at location: CGPoint, size: CGSize) {
        var curve = clip.speedCurve
        let snap = NSEvent.modifierFlags.contains(.shift)
        let speed = speedValue(at: location, size: size, snap: snap)
        let sourceOffset = sourceOffset(at: location, size: size, snap: snap)

        switch target {
        case .defaultValue:
            curve.defaultValue = speed
        case .keyframe(let id):
            curve.updateKeyframe(id: id, time: sourceOffset, value: speed)
        case .outgoing(let id):
            guard let index = curve.keyframes.firstIndex(where: { $0.id == id }),
                  index < curve.keyframes.index(before: curve.keyframes.endIndex) else { return }
            let keyframe = curve.keyframes[index]
            let next = curve.keyframes[index + 1]
            let clampedSource = CMTimeMinimum(CMTimeMaximum(keyframe.time, sourceOffset), next.time)
            let x = Float(fraction(clampedSource - keyframe.time, of: next.time - keyframe.time))
            curve.setOutgoingHandle(KeyframeHandle(x: x, y: speed), forKeyframe: id)
        case .incoming(let id):
            guard let index = curve.keyframes.firstIndex(where: { $0.id == id }),
                  index > curve.keyframes.startIndex else { return }
            let keyframe = curve.keyframes[index]
            let previous = curve.keyframes[index - 1]
            let clampedSource = CMTimeMinimum(CMTimeMaximum(previous.time, sourceOffset), keyframe.time)
            let x = Float(fraction(keyframe.time - clampedSource, of: keyframe.time - previous.time))
            curve.setIncomingHandle(KeyframeHandle(x: x, y: speed), forKeyframe: id)
        }

        onChange(curve)
    }

    private func outgoingHandle(for keyframe: Keyframe<Float>, next: Keyframe<Float>) -> KeyframeHandle {
        keyframe.outgoingHandle ?? KeyframeHandle(
            x: 1.0 / 3.0,
            y: keyframe.value + (next.value - keyframe.value) / 3)
    }

    private func incomingHandle(for keyframe: Keyframe<Float>, previous: Keyframe<Float>) -> KeyframeHandle {
        keyframe.incomingHandle ?? KeyframeHandle(
            x: 1.0 / 3.0,
            y: previous.value + (keyframe.value - previous.value) * 2 / 3)
    }

    private func outgoingPoint(_ handle: KeyframeHandle,
                               from keyframe: Keyframe<Float>,
                               to next: Keyframe<Float>,
                               size: CGSize,
                               plan: [TimeRemapSegment],
                               outputDuration: CMTime) -> CGPoint {
        let span = next.time - keyframe.time
        let source = keyframe.time + TimeRemapping.multiplied(span, by: Double(clampedUnit(handle.x)))
        return point(sourceOffset: source,
                     speed: handle.y,
                     size: size,
                     plan: plan,
                     outputDuration: outputDuration)
    }

    private func incomingPoint(_ handle: KeyframeHandle,
                               from previous: Keyframe<Float>,
                               to keyframe: Keyframe<Float>,
                               size: CGSize,
                               plan: [TimeRemapSegment],
                               outputDuration: CMTime) -> CGPoint {
        let span = keyframe.time - previous.time
        let source = keyframe.time - TimeRemapping.multiplied(span, by: Double(clampedUnit(handle.x)))
        return point(sourceOffset: source,
                     speed: handle.y,
                     size: size,
                     plan: plan,
                     outputDuration: outputDuration)
    }

    private func point(sourceOffset: CMTime,
                       speed: Float,
                       size: CGSize,
                       plan: [TimeRemapSegment],
                       outputDuration: CMTime) -> CGPoint {
        let rect = plotRect(size: size)
        let duration = max(outputDuration.seconds, 0.000_001)
        let output = TimeRemapping.outputOffset(forSourceOffset: sourceOffset, in: plan)
        let x = rect.minX + rect.width * CGFloat(min(1, max(0, output.seconds / duration)))
        let yFraction = CGFloat(
            (TimeRemapping.clampedSpeed(speed) - TimeRemapping.minSpeed)
                / (TimeRemapping.maxSpeed - TimeRemapping.minSpeed))
        let y = rect.maxY - rect.height * yFraction
        return CGPoint(x: x, y: y)
    }

    private func sourceOffset(at location: CGPoint, size: CGSize, snap: Bool) -> CMTime {
        let rect = plotRect(size: size)
        let xFraction = min(1, max(0, (location.x - rect.minX) / max(1, rect.width)))
        let output = CMTime(seconds: xFraction * max(0, clip.outputDuration.seconds),
                            preferredTimescale: 600)
        var source = clip.sourceOffset(forOutputOffset: output)
        if snap {
            let frame = 1.0 / max(1, frameRate)
            source = CMTime(seconds: (source.seconds / frame).rounded() * frame,
                            preferredTimescale: 600)
        }
        return CMTimeMinimum(CMTimeMaximum(.zero, source), clip.duration)
    }

    private func speedValue(at location: CGPoint, size: CGSize, snap: Bool) -> Float {
        let rect = plotRect(size: size)
        let yFraction = min(1, max(0, (rect.maxY - location.y) / max(1, rect.height)))
        var speed = TimeRemapping.minSpeed
            + Float(yFraction) * (TimeRemapping.maxSpeed - TimeRemapping.minSpeed)
        if snap {
            speed = (speed / 0.25).rounded() * 0.25
        }
        return TimeRemapping.clampedSpeed(speed)
    }

    private func plotRect(size: CGSize) -> CGRect {
        CGRect(x: inset,
               y: 6,
               width: max(1, size.width - inset * 2),
               height: max(1, size.height - 14))
    }

    private func fraction(_ time: CMTime, of duration: CMTime) -> Double {
        guard duration > .zero, duration.seconds.isFinite else { return 0 }
        return min(1, max(0, time.seconds / duration.seconds))
    }

    private func clampedUnit(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 / 3.0 }
        return min(1, max(0, value))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
