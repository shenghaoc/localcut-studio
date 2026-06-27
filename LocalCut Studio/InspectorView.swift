import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LocalCutCore

/// Context-sensitive properties for the current selection plus project-wide
/// render settings.
struct InspectorView: View {
    @Bindable var model: EditorModel
    @State private var showLUTImporter = false

    var body: some View {
        // The side rail's segmented switcher (EditorSideRailView) is the sole
        // heading for the Inspector pane — adding an EditorPanelHeader here
        // would duplicate the tab label and create a VoiceOver header echo.
        // Sibling Audio/Captions panes already comply (audit P2).
        Form {
            if let transition = model.selectedTransition {
                transitionSection(transition)
            } else if let clip = model.selectedClip {
                clipSection(clip)
                speedSection(clip)
                if clipIsVideo(clip) {
                    colourSection
                    beautySection
                } else {
                    AudioClipFadesInspectorView(model: model, clip: clip)
                }
            } else if let media = model.selectedMedia {
                mediaSection(media)
            } else {
                Section {
                    Text("Select a clip or media item.")
                        .foregroundStyle(.secondary)
                }
            }

            projectSection
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showLUTImporter,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importLUT(url: url)
            }
        }
    }

    private func clipIsVideo(_ clip: Clip) -> Bool {
        model.track(for: clip.id)?.kind == .video
    }

    @ViewBuilder
    private func clipSection(_ clip: Clip) -> some View {
        Section("Clip") {
            if let media = model.project.media(for: clip.mediaID) {
                InspectorPosterView(media: media)
            }
            LabeledContent("Start") {
                Text(TimeFormatting.timecode(clip.timelineStart.seconds)).monospacedDigit()
            }
            LabeledContent("Duration") {
                Text(TimeFormatting.timecode(clip.duration.seconds)).monospacedDigit()
            }

            LabeledSliderRow(
                label: "Opacity",
                display: "\(Int(clip.opacity * 100))%",
                value: Binding(
                    get: { Double(clip.opacity) },
                    set: { newValue in model.updateSelectedClipCoalesced("Adjust Opacity") { $0.opacity = Float(newValue) } }),
                range: 0...1,
                resetAction: {
                    model.updateSelectedClipCoalesced("Adjust Opacity") { $0.opacity = 1 }
                    model.commitCoalescedUndo()
                })
        }
    }

    // MARK: - Speed

    @ViewBuilder
    private func speedSection(_ clip: Clip) -> some View {
        Section("Speed") {
            SpeedCurveEditor(
                clip: clip,
                frameRate: model.project.frameRate,
                onChange: { curve in
                    model.updateSelectedClipTimeRemap { clip in
                        clip.speedCurve = curve
                    }
                },
                onCommit: {
                    model.commitCoalescedUndo()
                },
                onReset: {
                    model.updateSelectedClipTimeRemapDiscrete("Reset Speed Curve") { clip in
                        clip.speedCurve = TimeRemapping.identitySpeedCurve
                    }
                })

            LabeledSliderRow(
                label: "Speed",
                spokenLabel: "Clip Speed",
                display: String(format: "%.2fx", clip.speedCurve.defaultValue),
                spokenValue: String(format: "%.2f times", clip.speedCurve.defaultValue),
                value: speedDefaultBinding,
                range: Double(TimeRemapping.minSpeed)...Double(TimeRemapping.maxSpeed),
                step: 0.05,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                resetAction: {
                    speedDefaultBinding.wrappedValue = Double(TimeRemapping.identitySpeed)
                    model.commitCoalescedUndo()
                })

            LabeledContent("Output", value: TimeFormatting.timecode(model.selectedClipOutputDuration.seconds))

            Toggle("Preserve Pitch", isOn: preservePitchBinding)
                .toggleStyle(.switch)

            Picker("Algorithm", selection: pitchAlgorithmBinding) {
                ForEach(TimePitchAlgorithm.allCases) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
            .disabled(!clip.preservePitch)

            DisclosureGroup("Speed Keyframes") {
                LabeledContent("Source Time") {
                    Text(speedKeyframePlayheadLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Value") {
                    Text(String(format: "%.2fx", model.selectedClipSpeedAtPlayhead))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Count") {
                    Text("\(clip.speedCurve.keyframes.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    Button {
                        model.seekToPreviousSelectedClipSpeedKeyframe()
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .help("Previous keyframe")
                    .accessibilityLabel("Previous speed keyframe")
                    .disabled(!hasPreviousSpeedKeyframe)

                    Button {
                        model.addOrUpdateSelectedClipSpeedKeyframe()
                    } label: {
                        Label(speedKeyframeActionTitle, systemImage: speedKeyframeActionIcon)
                    }
                    .disabled(model.selectedClipSourceLocalPlayheadTime == nil)

                    Button(role: .destructive) {
                        model.removeSelectedClipSpeedKeyframe()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove keyframe")
                    .accessibilityLabel("Remove speed keyframe")
                    .disabled(model.selectedClipSpeedKeyframeAtPlayhead == nil)

                    Button {
                        model.seekToNextSelectedClipSpeedKeyframe()
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .help("Next keyframe")
                    .accessibilityLabel("Next speed keyframe")
                    .disabled(!hasNextSpeedKeyframe)
                }
                .controlSize(.small)
            }

            HStack {
                Button("Reset") { model.resetSelectedClipSpeed() }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private var speedDefaultBinding: Binding<Double> {
        Binding(
            get: { Double(model.selectedClip?.speedCurve.defaultValue ?? TimeRemapping.identitySpeed) },
            set: { newValue in
                model.updateSelectedClipTimeRemap { clip in
                    clip.speedCurve.defaultValue = Float(newValue)
                }
            })
    }

    private var preservePitchBinding: Binding<Bool> {
        Binding(
            get: { model.selectedClip?.preservePitch ?? true },
            set: { newValue in
                model.updateSelectedClipTimeRemap("Change Pitch Preservation", invalidateVideo: false) {
                    $0.preservePitch = newValue
                }
                model.commitCoalescedUndo()
            })
    }

    private var pitchAlgorithmBinding: Binding<TimePitchAlgorithm> {
        Binding(
            get: { model.selectedClip?.pitchAlgorithm ?? .timeDomain },
            set: { newValue in
                model.updateSelectedClipTimeRemap("Change Pitch Algorithm", invalidateVideo: false) {
                    $0.pitchAlgorithm = newValue
                }
                model.commitCoalescedUndo()
            })
    }

    private var speedKeyframePlayheadLabel: String {
        guard let localTime = model.selectedClipSourceLocalPlayheadTime else { return "Outside clip" }
        return TimeFormatting.timecode(localTime.seconds)
    }

    private var speedKeyframeActionTitle: String {
        model.selectedClipSpeedKeyframeAtPlayhead == nil ? "Add" : "Update"
    }

    private var speedKeyframeActionIcon: String {
        model.selectedClipSpeedKeyframeAtPlayhead == nil ? "plus.diamond.fill" : "diamond.fill"
    }

    private var hasPreviousSpeedKeyframe: Bool {
        guard let localTime = model.selectedClipSourceLocalPlayheadTime,
              let clip = model.selectedClip else { return false }
        return clip.speedCurve.keyframes.contains {
            $0.time.seconds < localTime.seconds
        }
    }

    private var hasNextSpeedKeyframe: Bool {
        guard let localTime = model.selectedClipSourceLocalPlayheadTime,
              let clip = model.selectedClip else { return false }
        return clip.speedCurve.keyframes.contains {
            $0.time.seconds > localTime.seconds
        }
    }

    // MARK: - Transition

    @ViewBuilder
    private func transitionSection(_ transition: LocalCutCore.Transition) -> some View {
        Section("Transition") {
            Picker("Type", selection: transitionTypeBinding) {
                ForEach(TransitionType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            // Show the effective (clamped) duration so the label can't exceed
            // the slider's ceiling after a neighbour is trimmed shorter.
            LabeledSliderRow(
                label: "Duration",
                spokenLabel: "Transition Duration",
                display: String(format: "%.2f s", min(transition.duration.seconds, maxTransitionSeconds)),
                spokenValue: String(format: "%.2f seconds", min(transition.duration.seconds, maxTransitionSeconds)),
                value: transitionDurationBinding,
                range: minTransitionSeconds...maxTransitionSeconds,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })

            if transition.type == .wipe {
                LabeledSliderRow(
                    label: "Direction",
                    spokenLabel: "Wipe Direction",
                    display: String(format: "%.0f deg", transitionWipeAngleDegrees),
                    spokenValue: String(format: "%.0f degrees", transitionWipeAngleDegrees),
                    value: transitionWipeAngleBinding,
                    range: 0...360,
                    step: 1,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: {
                        model.updateSelectedTransition(coalesced: true) {
                            $0.wipeAngle = Transition.defaultWipeAngle
                        }
                        model.commitCoalescedUndo()
                    })
            }

            Button(role: .destructive) {
                model.removeSelectedTransition()
            } label: {
                Label("Remove Transition", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    /// Shortest allowed transition (one render frame at the project frame rate).
    private var minTransitionSeconds: Double { 1.0 / max(1, model.project.frameRate) }

    /// Longest allowed transition: the available overlap, never below the min.
    private var maxTransitionSeconds: Double {
        max(model.selectedTransitionMaxDuration.seconds, minTransitionSeconds + 0.01)
    }

    private var transitionTypeBinding: Binding<TransitionType> {
        Binding(
            get: { model.selectedTransition?.type ?? .crossDissolve },
            set: { newValue in model.updateSelectedTransition { $0.type = newValue } })
    }

    private var transitionDurationBinding: Binding<Double> {
        Binding(
            get: { min(model.selectedTransition?.duration.seconds ?? 0, maxTransitionSeconds) },
            set: { newValue in
                model.updateSelectedTransition(coalesced: true) {
                    $0.duration = CMTime(seconds: newValue, preferredTimescale: 600)
                }
            })
    }

    private var transitionWipeAngleDegrees: Double {
        Transition.degrees(fromRadians: model.selectedTransition?.wipeAngle ?? Transition.defaultWipeAngle)
    }

    private var transitionWipeAngleBinding: Binding<Double> {
        Binding(
            get: { transitionWipeAngleDegrees },
            set: { newValue in
                model.updateSelectedTransition(coalesced: true) {
                    $0.wipeAngle = Transition.radians(fromDegrees: newValue)
                }
            })
    }

    // MARK: - Colour Grading

    @ViewBuilder
    private var colourSection: some View {
        Section("Colour") {
            LabeledSliderRow(label: "Exposure", display: String(format: "%+.2f", model.selectedClipGrade.exposure),
                             value: colourGradeBinding(\.exposure), range: -2...2, step: 0.05,
                             resetAction: resetColourGrade(\.exposure, to: 0))
            LabeledSliderRow(label: "Contrast", display: String(format: "%.2f", model.selectedClipGrade.contrast),
                             value: colourGradeBinding(\.contrast), range: 0.5...1.5, step: 0.05,
                             resetAction: resetColourGrade(\.contrast, to: 1))
            LabeledSliderRow(label: "Saturation", display: String(format: "%.2f", model.selectedClipGrade.saturation),
                             value: colourGradeBinding(\.saturation), range: 0...2, step: 0.05,
                             resetAction: resetColourGrade(\.saturation, to: 1))
            LabeledSliderRow(label: "Temp offset", spokenLabel: "Temperature Offset",
                             display: "\(String(format: "%+.0f", model.selectedClipGrade.temperatureOffset))K",
                             value: colourGradeBinding(\.temperatureOffset), range: -4000...4000, step: 100,
                             resetAction: resetColourGrade(\.temperatureOffset, to: 0))
            LabeledSliderRow(label: "Tint offset", spokenLabel: "Tint Offset",
                             display: String(format: "%+.0f", model.selectedClipGrade.tintOffset),
                             value: colourGradeBinding(\.tintOffset), range: -150...150, step: 10,
                             resetAction: resetColourGrade(\.tintOffset, to: 0))

            if model.selectedClipHasLUT {
                LabeledContent("LUT") {
                    HStack(spacing: 6) {
                        Text(model.selectedClipLUTName ?? "Applied")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(role: .destructive) {
                            model.removeLUT()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove LUT")
                        .accessibilityLabel("Remove LUT")
                    }
                }
            }

            HStack {
                Button(model.selectedClipHasLUT ? "Replace LUT…" : "Import LUT…") { showLUTImporter = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button("Reset") { model.resetClipColourEffects() }
                    .controlSize(.small)
            }
        }
    }

    /// Builds a reset closure for one colour-grade parameter: restores its
    /// neutral value through the coalesced setter and commits a single undo step.
    private func resetColourGrade(_ keyPath: WritableKeyPath<ColourGrade, Float>, to neutral: Float) -> () -> Void {
        {
            colourGradeBinding(keyPath).wrappedValue = neutral
            model.commitCoalescedUndo()
        }
    }

    private func colourGradeBinding(_ keyPath: WritableKeyPath<ColourGrade, Float>) -> Binding<Float> {
        Binding(
            get: { model.selectedClipGrade[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedClipCoalesced("Adjust Colour") { clip in
                    if let effectIndex = clip.effects.firstIndex(where: {
                        if case .colourGrade = $0 { return true }; return false
                    }) {
                        if case .colourGrade(var grade) = clip.effects[effectIndex] {
                            grade[keyPath: keyPath] = newValue
                            grade.clamp()
                            clip.effects[effectIndex] = .colourGrade(grade)
                        }
                    } else {
                        var grade = ColourGrade()
                        grade[keyPath: keyPath] = newValue
                        grade.clamp()
                        clip.effects.append(.colourGrade(grade))
                    }
                }
            }
        )
    }

    // MARK: - Beauty / Skin Smoothing

    @ViewBuilder
    private var beautySection: some View {
        Section("Beauty") {
            LabeledSliderRow(
                label: "Strength",
                display: "\(Int(model.selectedClipSkinSmooth.strength.defaultValue * 100))%",
                value: skinSmoothBinding(\.strength.defaultValue),
                range: 0...1
            )

            DisclosureGroup("Strength Keyframes") {
                LabeledContent("Clip Time") {
                    Text(skinSmoothKeyframePlayheadLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Value") {
                    Text("\(Int(model.selectedClipSkinSmoothStrengthAtPlayhead * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Count") {
                    Text("\(model.selectedClipSkinSmooth.strength.keyframes.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    Button {
                        model.seekToPreviousSelectedClipSkinSmoothStrengthKeyframe()
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .help("Previous keyframe")
                    .accessibilityLabel("Previous skin-smooth keyframe")
                    .disabled(!hasPreviousSkinSmoothKeyframe)

                    Button {
                        model.addOrUpdateSelectedClipSkinSmoothStrengthKeyframe()
                    } label: {
                        Label(skinSmoothKeyframeActionTitle, systemImage: skinSmoothKeyframeActionIcon)
                    }
                    .disabled(model.selectedClipSourceLocalPlayheadTime == nil)

                    Button(role: .destructive) {
                        model.removeSelectedClipSkinSmoothStrengthKeyframe()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove keyframe")
                    .accessibilityLabel("Remove skin-smooth keyframe")
                    .disabled(model.selectedClipSkinSmoothStrengthKeyframeAtPlayhead == nil)

                    Button {
                        model.seekToNextSelectedClipSkinSmoothStrengthKeyframe()
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .help("Next keyframe")
                    .accessibilityLabel("Next skin-smooth keyframe")
                    .disabled(!hasNextSkinSmoothKeyframe)
                }
                .controlSize(.small)
            }

            DisclosureGroup("Advanced") {
                LabeledSliderRow(
                    label: "Mask Warmth",
                    display: String(format: "%+.2f", model.selectedClipSkinSmooth.maskWarmthBias),
                    value: skinSmoothBinding(\.maskWarmthBias),
                    range: -1...1,
                    step: 0.05
                )

                LabeledSliderRow(
                    label: "Luminance Gate",
                    display: String(format: "%.2f", model.selectedClipSkinSmooth.maskLuminanceGate),
                    value: skinSmoothBinding(\.maskLuminanceGate),
                    range: 0...1,
                    step: 0.05
                )
            }

            Toggle("Bypass", isOn: Binding(
                get: { model.selectedClipSkinSmooth.bypass },
                set: { newValue in
                    model.updateSelectedClipSkinSmooth { smooth in
                        smooth.bypass = newValue
                    }
                }))
                .toggleStyle(.switch)

            Toggle("Show Mask", isOn: Binding(
                get: { model.showSkinMask },
                set: { newValue in
                    model.showSkinMask = newValue
                    model.scheduleRebuild()
                }))
                .toggleStyle(.switch)

            HStack {
                Button("Reset") { model.resetClipSkinSmooth() }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private var skinSmoothKeyframePlayheadLabel: String {
        guard let localTime = model.selectedClipSourceLocalPlayheadTime else { return "Outside clip" }
        return TimeFormatting.timecode(localTime.seconds)
    }

    private var skinSmoothKeyframeActionTitle: String {
        model.selectedClipSkinSmoothStrengthKeyframeAtPlayhead == nil ? "Add" : "Update"
    }

    private var skinSmoothKeyframeActionIcon: String {
        model.selectedClipSkinSmoothStrengthKeyframeAtPlayhead == nil ? "plus.diamond.fill" : "diamond.fill"
    }

    private var hasPreviousSkinSmoothKeyframe: Bool {
        guard let localTime = model.selectedClipSourceLocalPlayheadTime else { return false }
        return model.selectedClipSkinSmooth.strength.keyframes.contains {
            $0.time.seconds < localTime.seconds
        }
    }

    private var hasNextSkinSmoothKeyframe: Bool {
        guard let localTime = model.selectedClipSourceLocalPlayheadTime else { return false }
        return model.selectedClipSkinSmooth.strength.keyframes.contains {
            $0.time.seconds > localTime.seconds
        }
    }

    private func skinSmoothBinding(_ keyPath: WritableKeyPath<SkinSmoothEffect, Float>) -> Binding<Float> {
        Binding(
            get: { model.selectedClipSkinSmooth[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedClipSkinSmooth { smooth in
                    smooth[keyPath: keyPath] = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func mediaSection(_ media: MediaItem) -> some View {
        Section("Media") {
            InspectorPosterView(media: media)
            LabeledContent("Name", value: media.name)
            LabeledContent("Duration") {
                Text(TimeFormatting.timecode(media.durationSeconds)).monospacedDigit()
            }
            if media.hasVideo {
                LabeledContent("Size", value: "\(Int(media.naturalSize.width))×\(Int(media.naturalSize.height))")
            }
            LabeledContent("Tracks", value: [
                media.hasVideo ? "Video" : nil,
                media.hasAudio ? "Audio" : nil
            ].compactMap { $0 }.joined(separator: ", "))
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        Section("Project") {
            Picker("Resolution", selection: resolutionBinding) {
                Text("1920 × 1080").tag(CGSize(width: 1920, height: 1080))
                Text("1280 × 720").tag(CGSize(width: 1280, height: 720))
                Text("3840 × 2160").tag(CGSize(width: 3840, height: 2160))
                Text("1080 × 1920 (Vertical)").tag(CGSize(width: 1080, height: 1920))
            }
            Picker("Frame Rate", selection: frameRateBinding) {
                Text("24 fps").tag(24.0)
                Text("30 fps").tag(30.0)
                Text("60 fps").tag(60.0)
            }
        }
        Section("Colour") {
            Picker("Working Space", selection: workingColourSpaceBinding) {
                ForEach(WorkingColourSpace.allCases) { space in
                    Text(space.displayName).tag(space)
                }
            }
            .help("sRGB is the safe default. Display P3 / Rec.2020 are advanced — verify on a calibrated reference monitor.")

            if model.project.workingColourSpace != .sRGB {
                Text("Wide-gamut working space — verify on a calibrated reference monitor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Show scopes", isOn: $model.showScopes)
        }
    }

    private var resolutionBinding: Binding<CGSize> {
        Binding(
            get: { model.project.renderSize },
            set: { model.setRenderSize($0) })
    }

    private var frameRateBinding: Binding<Double> {
        Binding(
            get: { model.project.frameRate },
            set: { model.setFrameRate($0) })
    }

    private var workingColourSpaceBinding: Binding<WorkingColourSpace> {
        Binding(
            get: { model.project.workingColourSpace },
            set: { model.setWorkingColourSpace($0) })
    }
}

private enum SpeedCurveDragTarget: Equatable {
    case defaultValue
    case keyframe(UUID)
    case incoming(UUID)
    case outgoing(UUID)
}

private struct SpeedCurveEditor: View {
    let clip: Clip
    let frameRate: Double
    let onChange: (Keyframed<Float>) -> Void
    let onCommit: () -> Void
    let onReset: () -> Void

    @State private var dragTarget: SpeedCurveDragTarget?

    private let inset: CGFloat = 10
    private let handleRadius: CGFloat = 4
    private let keyframeRadius: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                drawGrid(context: &context, size: size)
                drawCurve(context: &context, size: size)
                drawHandles(context: &context, size: size)
                drawKeyframes(context: &context, size: size)
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
        .accessibilityValue("\(clip.speedCurve.keyframes.count) speed keyframes")
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let rect = plotRect(size: size)
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

    private func drawCurve(context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let samples = max(24, Int(size.width / 3))
        for index in 0...samples {
            let fraction = Double(index) / Double(samples)
            let sourceOffset = TimeRemapping.multiplied(clip.duration, by: fraction)
            let speed = TimeRemapping.speedValue(in: clip.speedCurve, at: sourceOffset)
            let point = point(sourceOffset: sourceOffset, speed: speed, size: size)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
    }

    private func drawHandles(context: inout GraphicsContext, size: CGSize) {
        let keyframes = clip.speedCurve.keyframes
        guard keyframes.count > 1 else { return }

        for index in keyframes.indices {
            let keyframe = keyframes[index]
            let keyPoint = point(sourceOffset: keyframe.time, speed: keyframe.value, size: size)
            if index < keyframes.index(before: keyframes.endIndex) {
                let handle = outgoingHandle(for: keyframe, next: keyframes[index + 1])
                let handlePoint = outgoingPoint(handle, from: keyframe, to: keyframes[index + 1], size: size)
                drawHandleLine(context: &context, from: keyPoint, to: handlePoint)
                drawHandleDot(context: &context, at: handlePoint)
            }
            if index > keyframes.startIndex {
                let handle = incomingHandle(for: keyframe, previous: keyframes[index - 1])
                let handlePoint = incomingPoint(handle, from: keyframes[index - 1], to: keyframe, size: size)
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

    private func drawKeyframes(context: inout GraphicsContext, size: CGSize) {
        let keyframes = clip.speedCurve.keyframes
        if keyframes.isEmpty {
            let point = point(sourceOffset: TimeRemapping.multiplied(clip.duration, by: 0.5),
                              speed: clip.speedCurve.defaultValue,
                              size: size)
            let rect = CGRect(x: point.x - keyframeRadius,
                              y: point.y - keyframeRadius,
                              width: keyframeRadius * 2,
                              height: keyframeRadius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.accentColor))
            return
        }

        for keyframe in keyframes {
            let point = point(sourceOffset: keyframe.time, speed: keyframe.value, size: size)
            let rect = CGRect(x: point.x - keyframeRadius,
                              y: point.y - keyframeRadius,
                              width: keyframeRadius * 2,
                              height: keyframeRadius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.accentColor))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
    }

    private func nearestTarget(to location: CGPoint, size: CGSize) -> SpeedCurveDragTarget? {
        let keyframes = clip.speedCurve.keyframes
        guard !keyframes.isEmpty else { return .defaultValue }

        var candidates: [(target: SpeedCurveDragTarget, distance: CGFloat)] = []
        for index in keyframes.indices {
            let keyframe = keyframes[index]
            let keyPoint = point(sourceOffset: keyframe.time, speed: keyframe.value, size: size)
            candidates.append((.keyframe(keyframe.id), distance(location, keyPoint)))
            if index < keyframes.index(before: keyframes.endIndex) {
                let handle = outgoingHandle(for: keyframe, next: keyframes[index + 1])
                let handlePoint = outgoingPoint(handle, from: keyframe, to: keyframes[index + 1], size: size)
                candidates.append((.outgoing(keyframe.id), distance(location, handlePoint)))
            }
            if index > keyframes.startIndex {
                let handle = incomingHandle(for: keyframe, previous: keyframes[index - 1])
                let handlePoint = incomingPoint(handle, from: keyframes[index - 1], to: keyframe, size: size)
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
                               size: CGSize) -> CGPoint {
        let span = next.time - keyframe.time
        let source = keyframe.time + TimeRemapping.multiplied(span, by: Double(clampedUnit(handle.x)))
        return point(sourceOffset: source, speed: handle.y, size: size)
    }

    private func incomingPoint(_ handle: KeyframeHandle,
                               from previous: Keyframe<Float>,
                               to keyframe: Keyframe<Float>,
                               size: CGSize) -> CGPoint {
        let span = keyframe.time - previous.time
        let source = keyframe.time - TimeRemapping.multiplied(span, by: Double(clampedUnit(handle.x)))
        return point(sourceOffset: source, speed: handle.y, size: size)
    }

    private func point(sourceOffset: CMTime, speed: Float, size: CGSize) -> CGPoint {
        let rect = plotRect(size: size)
        let outputDuration = max(clip.outputDuration.seconds, 0.000_001)
        let output = clip.outputOffset(forSourceOffset: sourceOffset)
        let x = rect.minX + rect.width * CGFloat(min(1, max(0, output.seconds / outputDuration)))
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

private struct InspectorPosterView: View {
    let media: MediaItem

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let thumbnail = media.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: media.hasVideo ? "film" : "waveform")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, idealHeight: 110, maxHeight: 120)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
