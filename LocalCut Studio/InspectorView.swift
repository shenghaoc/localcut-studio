import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import LocalCutCore

/// Context-sensitive properties for the current selection plus project-wide
/// render settings.
struct InspectorView: View {
    @Bindable var model: EditorModel
    @State private var showLUTImporter = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            Form {
                if let transition = model.selectedTransition {
                    transitionSection(transition)
                } else if let clip = model.selectedClip {
                    clipSection(clip)
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

                AudioInspectorView(model: model)
                CaptionsInspectorView(model: model)
                RenderQueueInspectorView(model: model)
                MarkersInspectorView(model: model)
                projectSection
            }
            .formStyle(.grouped)
        }
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
            LabeledContent("Start", value: TimeFormatting.timecode(clip.timelineStart.seconds))
            LabeledContent("Duration", value: TimeFormatting.timecode(clip.duration.seconds))

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
                    .disabled(model.selectedClipSkinSmoothLocalPlayheadTime == nil)

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
        guard let localTime = model.selectedClipSkinSmoothLocalPlayheadTime else { return "Outside clip" }
        return TimeFormatting.timecode(localTime.seconds)
    }

    private var skinSmoothKeyframeActionTitle: String {
        model.selectedClipSkinSmoothStrengthKeyframeAtPlayhead == nil ? "Add" : "Update"
    }

    private var skinSmoothKeyframeActionIcon: String {
        model.selectedClipSkinSmoothStrengthKeyframeAtPlayhead == nil ? "plus.diamond.fill" : "diamond.fill"
    }

    private var hasPreviousSkinSmoothKeyframe: Bool {
        guard let localTime = model.selectedClipSkinSmoothLocalPlayheadTime else { return false }
        return model.selectedClipSkinSmooth.strength.keyframes.contains {
            $0.time.seconds < localTime.seconds
        }
    }

    private var hasNextSkinSmoothKeyframe: Bool {
        guard let localTime = model.selectedClipSkinSmoothLocalPlayheadTime else { return false }
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
            LabeledContent("Name", value: media.name)
            LabeledContent("Duration", value: TimeFormatting.timecode(media.durationSeconds))
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
