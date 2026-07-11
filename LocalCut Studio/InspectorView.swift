import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LocalCutCore
import LocalCutDomain

/// Context-sensitive properties for the current selection plus project-wide
/// render settings.
struct InspectorView: View {
    @Bindable var model: EditorModel
    @State private var showLUTImporter = false
    @State private var showLookImporter = false

    var body: some View {
        // The side rail's segmented switcher (EditorSideRailView) is the sole
        // heading for the Inspector pane — adding an EditorPanelHeader here
        // would duplicate the tab label and create a VoiceOver header echo.
        // Sibling Audio/Captions panes already comply (audit P2).
        Form {
            if let transition = model.selectedTransition {
                transitionSection(transition)
            } else if let overlay = model.selectedOverlay {
                overlaySection(overlay)
            } else if let clip = model.selectedClip {
                clipSection(clip)
                speedSection(clip)
                if clipIsVideo(clip) {
                    colourSection
                    looksSection
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

            CoverInspectorView(model: model)
            projectSection
            overlayListSection
            ScreencastInspectorView(model: model)
            TutorialFinishingInspectorView(model: model)
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
        .fileImporter(
            isPresented: $showLookImporter,
            allowedContentTypes: [.localCutLookPreset],
            allowsMultipleSelection: false
        ) { [weak model] result in
            if case .success(let urls) = result, let url = urls.first {
                Task { [weak model] in
                    await model?.importLookPreset(url: url)
                }
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
                .toggleStyle(.checkbox)

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

    // MARK: - Look Packs

    @ViewBuilder
    private var looksSection: some View {
        Section("Looks") {
            Menu {
                ForEach(LookPresetLibrary.builtInPresets, id: \.name) { preset in
                    Button(preset.name) {
                        model.applyBuiltInLookPreset(preset)
                    }
                }
                Divider()
                Button("Import…", systemImage: "square.and.arrow.down") {
                    showLookImporter = true
                }
                Button("Export…", systemImage: "square.and.arrow.up") {
                    model.requestExportLookPreset()
                }
            } label: {
                Label("Preset", systemImage: "wand.and.stars")
            }

            DisclosureGroup("Grain") {
                LabeledSliderRow(
                    label: "Amount",
                    display: "\(Int(model.lookStrengthAtPlayhead(.grain) * 100))%",
                    value: grainBinding(\.amount.defaultValue),
                    range: 0...1,
                    step: 0.01,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetGrain(\.amount.defaultValue, to: 0))
                lookKeyframeEditor(.grain)
                LabeledSliderRow(
                    label: "Size",
                    display: String(format: "%.2f", model.selectedClipGrain.size),
                    value: grainBinding(\.size),
                    range: 0.25...8,
                    step: 0.05,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetGrain(\.size, to: 1))
                Toggle("Monochrome", isOn: Binding(
                    get: { model.selectedClipGrain.monochrome },
                    set: { newValue in
                        model.updateSelectedClipGrain { $0.monochrome = newValue }
                    }))
            }

            DisclosureGroup("Halation") {
                LabeledSliderRow(
                    label: "Strength",
                    display: "\(Int(model.lookStrengthAtPlayhead(.halation) * 100))%",
                    value: halationBinding(\.strength.defaultValue),
                    range: 0...1,
                    step: 0.01,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetHalation(\.strength.defaultValue, to: 0))
                lookKeyframeEditor(.halation)
                LabeledSliderRow(
                    label: "Threshold",
                    display: String(format: "%.2f", model.selectedClipHalation.threshold),
                    value: halationBinding(\.threshold),
                    range: 0...1,
                    step: 0.01,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetHalation(\.threshold, to: 0.72))
                LabeledSliderRow(
                    label: "Radius",
                    display: String(format: "%.0f px", model.selectedClipHalation.radius),
                    value: halationBinding(\.radius),
                    range: 0...80,
                    step: 1,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetHalation(\.radius, to: 16))
                LabeledSliderRow(
                    label: "Red Boost",
                    spokenLabel: "Red Boost",
                    display: String(format: "%.2f", model.selectedClipHalation.redBoost),
                    value: halationBinding(\.redBoost),
                    range: 0...2,
                    step: 0.05,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetHalation(\.redBoost, to: 0.85))
                    .help("Red/orange colour bias of the halation glow.")
            }

            DisclosureGroup("Vignette") {
                LabeledSliderRow(
                    label: "Amount",
                    display: "\(Int(model.lookStrengthAtPlayhead(.vignette) * 100))%",
                    value: vignetteBinding(\.amount.defaultValue),
                    range: -1...1,
                    step: 0.01,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetVignette(\.amount.defaultValue, to: 0))
                lookKeyframeEditor(.vignette)
                LabeledSliderRow(
                    label: "Radius",
                    display: String(format: "%.2f", model.selectedClipVignette.radius),
                    value: vignetteBinding(\.radius),
                    range: 0.05...2,
                    step: 0.01,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetVignette(\.radius, to: 0.65))
                LabeledSliderRow(
                    label: "Softness",
                    display: String(format: "%.2f", model.selectedClipVignette.softness),
                    value: vignetteBinding(\.softness),
                    range: 0.01...1,
                    step: 0.01,
                    onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                    resetAction: resetVignette(\.softness, to: 0.35))
            }

            HStack {
                Button("Import…") { showLookImporter = true }
                    .controlSize(.small)
                Button("Export…") { model.requestExportLookPreset() }
                    .controlSize(.small)
                    .disabled(!model.selectedClipHasLookEffects)
                Spacer()
                // Reset uses performUndoable (discrete action) while slider
                // adjustments use performCoalescedUndoable (continuous gesture).
                // This is intentional: reset is a one-shot action that should
                // create a single undo step, not be coalesced with prior drags.
                Button("Reset") { model.resetClipLooks() }
                    .controlSize(.small)
                    .disabled(!model.selectedClipHasLookEffects)
            }
        }
    }

    private func resetGrain(_ keyPath: WritableKeyPath<GrainEffect, Float>, to neutral: Float) -> () -> Void {
        {
            grainBinding(keyPath).wrappedValue = neutral
            model.commitCoalescedUndo()
        }
    }

    private func resetHalation(_ keyPath: WritableKeyPath<HalationEffect, Float>, to neutral: Float) -> () -> Void {
        {
            halationBinding(keyPath).wrappedValue = neutral
            model.commitCoalescedUndo()
        }
    }

    private func resetVignette(_ keyPath: WritableKeyPath<VignetteEffect, Float>, to neutral: Float) -> () -> Void {
        {
            vignetteBinding(keyPath).wrappedValue = neutral
            model.commitCoalescedUndo()
        }
    }

    private func grainBinding(_ keyPath: WritableKeyPath<GrainEffect, Float>) -> Binding<Float> {
        Binding(
            get: { model.selectedClipGrain[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedClipGrain { $0[keyPath: keyPath] = newValue }
            })
    }

    private func halationBinding(_ keyPath: WritableKeyPath<HalationEffect, Float>) -> Binding<Float> {
        Binding(
            get: { model.selectedClipHalation[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedClipHalation { $0[keyPath: keyPath] = newValue }
            })
    }

    private func vignetteBinding(_ keyPath: WritableKeyPath<VignetteEffect, Float>) -> Binding<Float> {
        Binding(
            get: { model.selectedClipVignette[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedClipVignette { $0[keyPath: keyPath] = newValue }
            })
    }

    /// Playhead-targeted keyframe editor for a look effect's strength parameter
    /// (grain amount, halation strength, vignette amount). Mirrors the
    /// skin-smoothing keyframe controls so all animated effects behave alike.
    @ViewBuilder
    private func lookKeyframeEditor(_ kind: LookEffectKind) -> some View {
        DisclosureGroup("Keyframes") {
            LabeledContent("Clip Time") {
                Text(lookKeyframePlayheadLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Value") {
                Text("\(Int(model.lookStrengthAtPlayhead(kind) * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Count") {
                Text("\(model.lookStrengthKeyframes(kind).count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button {
                    model.seekToPreviousLookStrengthKeyframe(kind)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("Previous keyframe")
                .accessibilityLabel("Previous \(kind.displayName) keyframe")
                .disabled(!hasPreviousLookKeyframe(kind))

                Button {
                    model.addOrUpdateLookStrengthKeyframe(kind)
                } label: {
                    Label(lookKeyframeActionTitle(kind), systemImage: lookKeyframeActionIcon(kind))
                }
                .disabled(model.selectedClipLookLocalPlayheadTime == nil)

                Button(role: .destructive) {
                    model.removeLookStrengthKeyframe(kind)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove keyframe")
                .accessibilityLabel("Remove \(kind.displayName) keyframe")
                .disabled(model.lookStrengthKeyframeAtPlayhead(kind) == nil)

                Button {
                    model.seekToNextLookStrengthKeyframe(kind)
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .help("Next keyframe")
                .accessibilityLabel("Next \(kind.displayName) keyframe")
                .disabled(!hasNextLookKeyframe(kind))
            }
            .controlSize(.small)
        }
    }

    private var lookKeyframePlayheadLabel: String {
        guard let localTime = model.selectedClipLookLocalPlayheadTime else { return "Outside clip" }
        return TimeFormatting.timecode(localTime.seconds)
    }

    private func lookKeyframeActionTitle(_ kind: LookEffectKind) -> String {
        model.lookStrengthKeyframeAtPlayhead(kind) == nil ? "Add" : "Update"
    }

    private func lookKeyframeActionIcon(_ kind: LookEffectKind) -> String {
        model.lookStrengthKeyframeAtPlayhead(kind) == nil ? "plus.diamond.fill" : "diamond.fill"
    }

    private func hasPreviousLookKeyframe(_ kind: LookEffectKind) -> Bool {
        guard let localTime = model.selectedClipLookLocalPlayheadTime else { return false }
        return model.lookStrengthKeyframes(kind).contains { $0.time.seconds < localTime.seconds }
    }

    private func hasNextLookKeyframe(_ kind: LookEffectKind) -> Bool {
        guard let localTime = model.selectedClipLookLocalPlayheadTime else { return false }
        return model.lookStrengthKeyframes(kind).contains { $0.time.seconds > localTime.seconds }
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
                .toggleStyle(.checkbox)

            Toggle("Show Mask", isOn: Binding(
                get: { model.showSkinMask },
                set: { newValue in
                    model.showSkinMask = newValue
                    model.scheduleRebuild()
                }))
                .toggleStyle(.checkbox)

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
            Picker("Aspect", selection: aspectBinding) {
                ForEach(ProjectAspect.builtIns) { aspect in
                    Text(aspect.displayName).tag(aspect)
                }
                Text("Custom").tag(ProjectAspect.custom)
            }
            .help("Choose the project canvas aspect ratio for preview and export")
            .accessibilityLabel("Project canvas aspect ratio")
            if model.project.aspect == .custom {
                LabeledContent("Width") {
                    TextField("Width", value: customWidthBinding, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .help("Enter a custom canvas width in pixels")
                        .accessibilityLabel("Custom canvas width in pixels")
                }
                LabeledContent("Height") {
                    TextField("Height", value: customHeightBinding, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .help("Enter a custom canvas height in pixels")
                        .accessibilityLabel("Custom canvas height in pixels")
                }
            } else {
                LabeledContent("Canvas") {
                    Text("\(Int(model.project.renderSize.width))×\(Int(model.project.renderSize.height))")
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Frame Rate", selection: frameRateBinding) {
                Text("24 fps").tag(24.0)
                Text("30 fps").tag(30.0)
                Text("60 fps").tag(60.0)
            }
            .help("Choose the project frame rate in frames per second")
            .accessibilityLabel("Project frame rate")
        }
        Section("Safe Zones") {
            Toggle("Show Safe Zones", isOn: $model.showSafeZones)
                .help("Overlay platform-specific safe-zone guides on the preview canvas")
                .onChange(of: model.showSafeZones) { _, newValue in
                    if newValue { model.surfaceSafeZoneLoadErrors() }
                }
            Picker("Platform", selection: $model.selectedSafeZoneProfileID) {
                ForEach(SafeZoneLibrary.builtInProfiles) { profile in
                    Text(profile.displayName).tag(profile.platformID)
                }
            }
            .help("Choose a platform safe-zone profile (TikTok, YouTube Shorts, Instagram Reels, etc.)")
            .accessibilityLabel("Safe zone platform profile")
            if let profile = model.selectedSafeZoneProfile,
               !SafeZoneLibrary.isProfile(
                profile,
                compatibleWith: model.project.aspect,
                renderSize: model.project.renderSize) {
                Text("Switch the project aspect to \(profile.aspect.displayName) to show this overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .help("Show waveform and vectorscope panels beside the preview")
        }
    }


    private var aspectBinding: Binding<ProjectAspect> {
        Binding(
            get: { model.project.aspect },
            set: { model.setProjectAspect($0) })
    }

    private var customWidthBinding: Binding<Double> {
        Binding(
            get: { model.project.renderSize.width },
            set: { newValue in
                model.setRenderSize(CGSize(width: newValue, height: model.project.renderSize.height))
            })
    }

    private var customHeightBinding: Binding<Double> {
        Binding(
            get: { model.project.renderSize.height },
            set: { newValue in
                model.setRenderSize(CGSize(width: model.project.renderSize.width, height: newValue))
            })
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

    // MARK: - Overlay inspector

    @ViewBuilder
    private func overlaySection(_ overlay: OverlayClip) -> some View {
        let frameStep = 1 / max(1, model.project.frameRate)
        let timelineUpper = max(60, model.totalDuration, overlay.timelineEnd.seconds)
        let durationUpper = max(frameStep, max(60, model.totalDuration, overlay.duration.seconds))
        Section("Overlay") {
            LabeledContent("Type") {
                Text(overlay.sourceType.displayName)
            }

            LabeledSliderRow(
                label: "Start",
                display: TimeFormatting.timecode(overlay.timelineStart.seconds),
                value: Binding(
                    get: { overlay.timelineStart.seconds },
                    set: {
                        model.setOverlayStart(
                            overlay.id,
                            to: CMTime(seconds: $0, preferredTimescale: 600))
                    }),
                range: 0...timelineUpper,
                step: frameStep,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })

            LabeledSliderRow(
                label: "Duration",
                display: TimeFormatting.timecode(overlay.duration.seconds),
                value: Binding(
                    get: { overlay.duration.seconds },
                    set: {
                        model.setOverlayDuration(
                            overlay.id,
                            to: CMTime(seconds: $0, preferredTimescale: 600))
                    }),
                range: frameStep...durationUpper,
                step: frameStep,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } })

            LabeledSliderRow(
                label: "Position X",
                display: "\(Int(overlay.positionOffset.width * 100))%",
                value: Binding(
                    get: { overlay.positionOffset.width },
                    set: {
                        model.setOverlayPosition(
                            overlay.id,
                            to: CGSize(width: $0, height: overlay.positionOffset.height))
                    }),
                range: -1...1,
                step: 0.01,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                resetAction: {
                    model.setOverlayPosition(
                        overlay.id,
                        to: CGSize(width: 0, height: overlay.positionOffset.height))
                    model.commitCoalescedUndo()
                })
                .help("Horizontal offset from centre. 0% = centred; ±100% = shifted by one full canvas width.")

            LabeledSliderRow(
                label: "Position Y",
                display: "\(Int(overlay.positionOffset.height * 100))%",
                value: Binding(
                    get: { overlay.positionOffset.height },
                    set: {
                        model.setOverlayPosition(
                            overlay.id,
                            to: CGSize(width: overlay.positionOffset.width, height: $0))
                    }),
                range: -1...1,
                step: 0.01,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                resetAction: {
                    model.setOverlayPosition(
                        overlay.id,
                        to: CGSize(width: overlay.positionOffset.width, height: 0))
                    model.commitCoalescedUndo()
                })
                .help("Vertical offset from centre. 0% = centred; ±100% = shifted by one full canvas height.")

            LabeledSliderRow(
                label: "Opacity",
                display: "\(Int(overlay.opacity * 100))%",
                value: Binding(
                    get: { Double(overlay.opacity) },
                    set: { model.setOverlayOpacity(overlay.id, to: Float($0)) }),
                range: 0...1,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                resetAction: {
                    model.setOverlayOpacity(overlay.id, to: 1)
                    model.commitCoalescedUndo()
                })

            LabeledSliderRow(
                label: "Scale",
                display: String(format: "%.1f×", overlay.scale),
                value: Binding(
                    get: { overlay.scale },
                    set: { model.setOverlayScale(overlay.id, to: $0) }),
                range: 0.1...4.0,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                resetAction: {
                    model.setOverlayScale(overlay.id, to: 1)
                    model.commitCoalescedUndo()
                })
                .help("Uniform scale factor. 1× = original size.")

            LabeledSliderRow(
                label: "Rotation",
                display: String(format: "%.0f°", overlay.rotation * 180 / .pi),
                value: Binding(
                    get: { overlay.rotation },
                    set: { model.setOverlayRotation(overlay.id, to: $0) }),
                range: -CGFloat.pi...CGFloat.pi,
                onEditingChanged: { if !$0 { model.commitCoalescedUndo() } },
                resetAction: {
                    model.setOverlayRotation(overlay.id, to: 0)
                    model.commitCoalescedUndo()
                })
                .help("Rotation in degrees. Positive = clockwise.")

            Picker("End Action", selection: Binding(
                get: { overlay.endAction },
                set: { model.setOverlayEndAction(overlay.id, to: $0) })) {
                ForEach(OverlayEndAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .help("What happens when the overlay source reaches its end: Hide (stop), Freeze (hold last frame), or Loop.")

            overlayKeyframeSection(overlay)

            Button("Remove Overlay", role: .destructive) {
                model.removeOverlay(id: overlay.id)
            }
        }
    }

    @ViewBuilder
    private func overlayKeyframeSection(_ overlay: OverlayClip) -> some View {
        let localTime = overlayLocalPlayheadTime(overlay)
        DisclosureGroup("Animation Keyframes") {
            HStack {
                Text(localTime.map { "At \(TimeFormatting.timecode($0.seconds))" } ?? "Move playhead over overlay")
                    .font(.caption)
                    .foregroundStyle(localTime == nil ? .orange : .secondary)
                Spacer()
                if overlay.isAnimated {
                    Text("Animated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .help(localTime == nil
                  ? "Scrub the playhead to a position within this overlay to add animation keyframes."
                  : "Add keyframes at the current time to animate the overlay.")

            HStack(spacing: 8) {
                Button {
                    addOrUpdateOverlayKeyframe(overlay, localTime: localTime)
                } label: {
                    Label("Add Keyframe", systemImage: "plus.diamond.fill")
                }
                .disabled(localTime == nil)

                Button(role: .destructive) {
                    model.removeOverlayKeyframes(at: overlay.id, localTime: localTime)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove keyframes at current time")
                .accessibilityLabel("Remove overlay keyframes at current time")
                .disabled(localTime == nil || !overlay.isAnimated)

                if overlay.isAnimated {
                    Button(role: .destructive) {
                        model.clearOverlayKeyframes(overlay.id)
                    } label: {
                        Text("Clear All")
                            .font(.caption)
                    }
                }
            }
            .controlSize(.small)
        }
        .help("Animate position, scale, rotation, and opacity over time using keyframes.")
    }

    private func overlayLocalPlayheadTime(_ overlay: OverlayClip) -> CMTime? {
        let playhead = CMTime(seconds: model.currentTime, preferredTimescale: 600)
        guard playhead >= overlay.timelineStart, playhead < overlay.timelineEnd else { return nil }
        return playhead - overlay.timelineStart
    }

    private func addOrUpdateOverlayKeyframe(_ overlay: OverlayClip, localTime: CMTime?) {
        guard let localTime else { return }
        model.addOrUpdateOverlayKeyframe(
            at: overlay.id,
            localTime: localTime,
            positionX: Float(overlay.positionOffset.width),
            positionY: Float(overlay.positionOffset.height),
            scale: Float(overlay.scale),
            rotation: Float(overlay.rotation),
            opacity: overlay.opacity)
    }

    // MARK: - Overlay list

    @State private var showOverlayImporter = false
    @State private var pendingOverlayType: OverlaySourceType = .animatedImage

    @ViewBuilder
    private var overlayListSection: some View {
        Section("Overlays") {
            if model.project.overlays.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No overlays. Add an animated image, alpha video, or Lottie overlay to the project.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    addOverlayMenu
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else {
                HStack {
                    addOverlayMenu
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                }

                ForEach(model.project.overlays) { overlay in
                    HStack {
                        Circle()
                            .fill(model.selectedOverlayID == overlay.id ? Color.accentColor : Color.clear)
                            .frame(width: 8, height: 8)
                        Text(overlay.sourceType.displayName)
                        Spacer()
                        Text(TimeFormatting.timecode(overlay.timelineStart.seconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectOverlay(overlay.id)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("\(overlay.sourceType.displayName) overlay at \(TimeFormatting.timecode(overlay.timelineStart.seconds))")
                }
                .onDelete { indexSet in
                    // Remove in descending order so earlier removals don't shift
                    // the indices of later entries.
                    for index in indexSet.sorted().reversed() {
                        model.removeOverlay(id: model.project.overlays[index].id)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showOverlayImporter,
            allowedContentTypes: pendingOverlayType.allowedContentTypes,
            allowsMultipleSelection: false
        ) { [weak model] result in
            if case .success(let urls) = result, let url = urls.first {
                Task { [weak model] in
                    await model?.importOverlay(from: url, sourceType: pendingOverlayType)
                }
            }
        }
    }

    private var addOverlayMenu: some View {
        Menu {
            Button("Animated Image (GIF/WebP/APNG)") {
                pendingOverlayType = .animatedImage
                showOverlayImporter = true
            }
            Button("Alpha Video") {
                pendingOverlayType = .alphaVideo
                showOverlayImporter = true
            }
            Button("Lottie") {
                pendingOverlayType = .lottie
                showOverlayImporter = true
            }
        } label: {
            Label("Add Overlay", systemImage: "plus")
        }
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
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, idealHeight: 110, maxHeight: 120)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}


/// Extracted view to isolate `@Observable` high-frequency updates (like `model.currentTime`)
/// from the main `InspectorView.body`, preventing unnecessary re-renders of the entire form during playback.
private struct CoverInspectorView: View {
    @Bindable var model: EditorModel
    @State private var coverPreviewImage: NSImage?
    @State private var coverPreviewIsLoading = false
    @State private var coverPreviewError: String?

    var body: some View {
        Section("Cover") {
            coverPreview
            LabeledContent("Time") {
                Text(coverTimeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Button {
                    model.nudgeCoverFrame(byFrames: -1)
                } label: {
                    Label("Previous Frame", systemImage: "backward.frame")
                }
                .labelStyle(.iconOnly)
                .disabled(model.totalDuration <= 0)
                .controlSize(.small)
                .help("Move cover frame back one frame")
                .accessibilityLabel("Move cover frame back one frame")

                Button("Set to Playhead") {
                    model.setCoverTimeToPlayhead()
                }
                .controlSize(.small)
                .help("Use the current playhead position as the cover frame time")
                .accessibilityLabel("Set cover frame to current playhead position")

                Button {
                    model.nudgeCoverFrame(byFrames: 1)
                } label: {
                    Label("Next Frame", systemImage: "forward.frame")
                }
                .labelStyle(.iconOnly)
                .disabled(model.totalDuration <= 0)
                .controlSize(.small)
                .help("Move cover frame forward one frame")
                .accessibilityLabel("Move cover frame forward one frame")
                Spacer()
            }
            Picker("Format", selection: coverFormatBinding) {
                ForEach(CoverFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .help("Choose the cover image output format (PNG, JPEG, or HEIC)")
            .accessibilityLabel("Cover image output format")
            TextField("Title", text: coverTitleBinding)
                .help("Optional title text drawn onto the cover image")
                .accessibilityLabel("Cover title text")
                .onSubmit { model.commitCoalescedUndo() }
            HStack {
                Button {
                    exportCoverTapped()
                } label: {
                    Label("Export Cover…", systemImage: "photo")
                }
                .help("Save the cover image to a file")
                .disabled(model.totalDuration <= 0)
                .controlSize(.small)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(maxWidth: .infinity)
                .aspectRatio(coverPreviewAspectRatio, contentMode: .fit)
            if let coverPreviewImage {
                Image(nsImage: coverPreviewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if coverPreviewIsLoading {
                ProgressView()
            } else if let coverPreviewError {
                Text(coverPreviewError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
        .frame(maxHeight: 180)
        .task(id: coverPreviewKey) {
            await refreshCoverPreview()
        }
    }

    private var coverPreviewAspectRatio: CGFloat {
        let size = model.project.renderSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return 16.0 / 9.0
        }
        return size.width / size.height
    }

    private var coverPreviewKey: String {
        let cover = model.project.coverFrame
        let title = cover?.title?.text ?? ""
        let isPlaying = model.isPlaying
        let time = cover?.time.cmTime.sanitized.seconds ?? (isPlaying ? -1 : model.currentTime)
        return [
            "\(CoverPreviewInvalidationKey.make(for: model.project))",
            "\(isPlaying)",
            "\(time)",
            cover?.format.rawValue ?? CoverFormat.png.rawValue,
            title,
            "\(model.project.renderSize.width)x\(model.project.renderSize.height)",
            model.project.workingColourSpace.rawValue,
        ].joined(separator: "|")
    }

    private func refreshCoverPreview() async {
        guard model.totalDuration > 0, !model.isPlaying else {
            if model.totalDuration <= 0 {
                coverPreviewImage = nil
                coverPreviewError = nil
            }
            coverPreviewIsLoading = false
            return
        }
        coverPreviewIsLoading = true
        coverPreviewError = nil
        coverPreviewImage = nil
        do {
            let data = try await model.makeCoverImageData()
            guard !Task.isCancelled else {
                coverPreviewIsLoading = false
                return
            }
            coverPreviewImage = NSImage(data: data)
            coverPreviewError = coverPreviewImage == nil ? "Cover preview unavailable." : nil
        } catch {
            guard !Task.isCancelled else {
                coverPreviewIsLoading = false
                return
            }
            coverPreviewImage = nil
            coverPreviewError = "Cover preview unavailable."
        }
        coverPreviewIsLoading = false
    }

    private var coverTimeLabel: String {
        let time = model.project.coverFrame?.time.cmTime.sanitized.seconds ?? model.currentTime
        return TimeFormatting.timecode(time)
    }

    private var coverFormatBinding: Binding<CoverFormat> {
        Binding(
            get: { model.project.coverFrame?.format ?? .png },
            set: { model.setCoverFormat($0) })
    }

    private var coverTitleBinding: Binding<String> {
        Binding(
            get: { model.project.coverFrame?.title?.text ?? "" },
            set: { model.setCoverTitle($0) })
    }

    private func exportCoverTapped() {
        let format = model.project.coverFrame?.format ?? .png
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(model.project.name)-cover.\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak model] in await model?.exportCover(to: url) }
    }
}
