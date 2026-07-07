import SwiftUI
import CoreMedia
import LocalCutCore
import UniformTypeIdentifiers

/// Inspector section for Phase 43 screencast post-pack tools: zoom-n-pan
/// presets, auto-zoom proposals, callouts, and padded background.
struct ScreencastInspectorView: View {
    @Bindable var model: EditorModel
    @State private var showAutoZoomReview = false
    @State private var showEventLogImporter = false
    @State private var showBackgroundImageImporter = false

    var body: some View {
        Section("Screencast Tools") {
            zoomPanSection
            calloutSection
            paddedBackgroundSection
            autoZoomSection
        }
        .sheet(isPresented: $showAutoZoomReview) {
            AutoZoomReviewSheet(model: model, isPresented: $showAutoZoomReview)
        }
        .fileImporter(
            isPresented: $showEventLogImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importScreencastEventLog(url: url)
            }
        }
        .fileImporter(
            isPresented: $showBackgroundImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.applyPaddedBackgroundImage(url: url)
            }
        }
    }

    // MARK: - Zoom-n-Pan

    @ViewBuilder
    private var zoomPanSection: some View {
        if model.selectedClip != nil {
            DisclosureGroup("Zoom-n-Pan Presets") {
                ForEach(ZoomPanPresetKind.allCases, id: \.self) { kind in
                    Button(kind.displayName) {
                        model.applyZoomPanPreset(kind: kind)
                    }
                    .accessibilityHint("Apply \(kind.displayName) preset to the selected clip")
                }
            }
            ClipTransformKeyframeEditor(model: model)
        }
    }

    // MARK: - Callouts

    @ViewBuilder
    private var calloutSection: some View {
        DisclosureGroup("Add Callout") {
            ForEach(CalloutKind.allCases, id: \.self) { kind in
                Button(kind.displayName) {
                    model.addCallout(kind: kind)
                }
            }
        }

        // List existing callouts so users can reselect them for editing.
        if !model.project.callouts.isEmpty {
            DisclosureGroup("Callouts (\(model.project.callouts.count))") {
                ForEach(model.project.callouts) { callout in
                    Button {
                        model.selectedCalloutID = callout.id
                    } label: {
                        HStack {
                            Text(callout.kind.displayName)
                            Spacer()
                            Text(String(format: "%.1fs", callout.timeRange.start.seconds))
                                .foregroundStyle(.secondary)
                            if callout.id == model.selectedCalloutID {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(callout.kind.displayName) callout at \(String(format: "%.1f", callout.timeRange.start.seconds)) seconds")
                    .accessibilityAddTraits(
                        callout.id == model.selectedCalloutID ? .isSelected : []
                    )
                }
            }
        }

        if let calloutID = model.selectedCalloutID,
           let callout = model.callout(for: calloutID) {
            calloutParameterEditor(callout)
        }
    }

    /// Creates a binding that dynamically fetches the latest callout from the
    /// model by ID, avoiding stale captures during rapid slider updates.
    /// The binding is lightweight (no allocation beyond the closure captures)
    /// and the getter performs an O(n) search through callouts, which is
    /// acceptable for typical callout counts (< 20).
    private func calloutBinding(for callout: CalloutClip) -> Binding<CalloutClip> {
        let calloutID = callout.id
        return Binding(
            get: { model.callout(for: calloutID) ?? callout },
            set: { model.updateCallout($0) }
        )
    }

    @ViewBuilder
    private func calloutParameterEditor(_ callout: CalloutClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(callout.kind.displayName)
                .font(.headline)

            switch callout.kind {
            case .arrow:
                arrowEditor(callout)
            case .box:
                boxEditor(callout)
            case .stepNumber:
                stepNumberEditor(callout)
            case .spotlight:
                spotlightEditor(callout)
            case .blurRegion:
                blurRegionEditor(callout)
            }

            calloutTransformEditor(callout)

            Button("Remove Callout", role: .destructive) {
                model.removeCallout(id: callout.id)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func arrowEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        HStack {
            Text("Stroke")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.arrowStyle.strokeWidth) },
                set: { var c = binding.wrappedValue; c.arrowStyle.strokeWidth = Float($0); binding.wrappedValue = c }),
                   in: 1...10, step: 1)
                .accessibilityLabel("Stroke")
                .accessibilityValue("\(Int(binding.wrappedValue.arrowStyle.strokeWidth))")
        }
    }

    @ViewBuilder
    private func boxEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        HStack {
            Text("Corner Radius")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.boxStyle.cornerRadius) },
                set: { var c = binding.wrappedValue; c.boxStyle.cornerRadius = Float($0); binding.wrappedValue = c }),
                   in: 0...30, step: 1)
                .accessibilityLabel("Corner Radius")
                .accessibilityValue("\(Int(binding.wrappedValue.boxStyle.cornerRadius))")
        }
    }

    @ViewBuilder
    private func stepNumberEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        HStack {
            Text("Number")
            TextField("Step", value: Binding(
                get: { binding.wrappedValue.stepNumber },
                set: { var c = binding.wrappedValue; c.stepNumber = max(1, $0); binding.wrappedValue = c }),
                      format: .number)
            .frame(width: 60)
        }
    }

    @ViewBuilder
    private func spotlightEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        HStack {
            Text("Radius")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.spotlightStyle.radius) },
                set: { var c = binding.wrappedValue; c.spotlightStyle.radius = Float($0); binding.wrappedValue = c }),
                   in: 0.02...0.5, step: 0.01)
                .accessibilityLabel("Radius")
                .accessibilityValue(String(format: "%.2f", binding.wrappedValue.spotlightStyle.radius))
        }
        HStack {
            Text("Dim")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.spotlightStyle.dimOpacity) },
                set: { var c = binding.wrappedValue; c.spotlightStyle.dimOpacity = Float($0); binding.wrappedValue = c }),
                   in: 0...1, step: 0.05)
                .accessibilityLabel("Dim")
                .accessibilityValue(String(format: "%.0f%%", binding.wrappedValue.spotlightStyle.dimOpacity * 100))
        }
    }

    @ViewBuilder
    private func blurRegionEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        HStack {
            Text("Blur")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.blurRegionStyle.blurRadius) },
                set: { var c = binding.wrappedValue; c.blurRegionStyle.blurRadius = Float($0); binding.wrappedValue = c }),
                   in: 1...50, step: 1)
                .accessibilityLabel("Blur")
                .accessibilityValue("\(Int(binding.wrappedValue.blurRegionStyle.blurRadius))")
        }
    }

    @ViewBuilder
    private func calloutTransformEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        DisclosureGroup("Transform") {
            LabeledContent("Position X") {
                TextField("X", value: Binding(
                    get: { Double(binding.wrappedValue.positionOffset.width) },
                    set: { var c = binding.wrappedValue; c.positionOffset.width = CGFloat($0); binding.wrappedValue = c }),
                          format: .number.precision(.fractionLength(3)))
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Position Y") {
                TextField("Y", value: Binding(
                    get: { Double(binding.wrappedValue.positionOffset.height) },
                    set: { var c = binding.wrappedValue; c.positionOffset.height = CGFloat($0); binding.wrappedValue = c }),
                          format: .number.precision(.fractionLength(3)))
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Scale")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { binding.wrappedValue.scale },
                    set: { binding.wrappedValue.scale = $0 }),
                       in: 0.25...4, step: 0.05)
                    .accessibilityLabel("Scale")
                    .accessibilityValue(String(format: "%.2fx", binding.wrappedValue.scale))
                Text(String(format: "%.2fx", binding.wrappedValue.scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack {
                Text("Rotation")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { binding.wrappedValue.rotation * 180 / .pi },
                    set: { binding.wrappedValue.rotation = $0 * .pi / 180 }),
                       in: -180...180, step: 1)
                    .accessibilityLabel("Rotation")
                    .accessibilityValue("\(Int(Double(binding.wrappedValue.rotation) * 180 / Double.pi)) degrees")
                Text("\(Int(Double(binding.wrappedValue.rotation) * 180 / Double.pi)) deg")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            calloutKeyframeEditor
        }
    }

    @ViewBuilder
    private var calloutKeyframeEditor: some View {
        DisclosureGroup("Transform Keyframes") {
            LabeledContent("Local Time") {
                Text(model.selectedCalloutLocalPlayheadTime.map { TimeFormatting.timecode($0.seconds) } ?? "--:--")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Count") {
                Text("\(model.selectedCalloutTransformKeyframeCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button {
                    model.seekToPreviousSelectedCalloutTransformKeyframe()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("Previous keyframe")
                .accessibilityLabel("Previous callout transform keyframe")

                Button {
                    model.addOrUpdateSelectedCalloutTransformKeyframe()
                } label: {
                    Label(model.selectedCalloutTransformKeyframeAtPlayhead == nil ? "Add" : "Update",
                          systemImage: model.selectedCalloutTransformKeyframeAtPlayhead == nil ? "plus.diamond.fill" : "diamond.fill")
                }
                .disabled(model.selectedCalloutLocalPlayheadTime == nil)

                Button(role: .destructive) {
                    model.removeSelectedCalloutTransformKeyframe()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove keyframe")
                .accessibilityLabel("Remove callout transform keyframe")
                .disabled(model.selectedCalloutTransformKeyframeAtPlayhead == nil)

                Button {
                    model.seekToNextSelectedCalloutTransformKeyframe()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .help("Next keyframe")
                .accessibilityLabel("Next callout transform keyframe")
            }
            .controlSize(.small)

            if model.selectedCalloutTransformKeyframeAtPlayhead != nil {
                calloutKeyframeValueEditor
            }
        }
    }

    @ViewBuilder
    private var calloutKeyframeValueEditor: some View {
        let value = model.selectedCalloutTransformAtPlayhead
        LabeledContent("Keyframe X") {
            TextField("X", value: Binding(
                get: { Double(model.selectedCalloutTransformAtPlayhead.tx) },
                set: { model.updateSelectedCalloutTransformKeyframeValue(value.replacing(translateX: Float($0))) }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Keyframe Y") {
            TextField("Y", value: Binding(
                get: { Double(model.selectedCalloutTransformAtPlayhead.ty) },
                set: { model.updateSelectedCalloutTransformKeyframeValue(value.replacing(translateY: Float($0))) }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
        }
        HStack {
            Text("Keyframe Scale")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(model.selectedCalloutTransformAtPlayhead.decomposedScale) },
                set: { model.updateSelectedCalloutTransformKeyframeValue(value.replacing(scale: Float($0))) }),
                   in: 0.1...4, step: 0.05)
                .accessibilityLabel("Keyframe Scale")
                .accessibilityValue(String(format: "%.2fx", model.selectedCalloutTransformAtPlayhead.decomposedScale))
        }
        HStack {
            Text("Keyframe Rotation")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(model.selectedCalloutTransformAtPlayhead.decomposedRotation) * 180 / Double.pi },
                set: { model.updateSelectedCalloutTransformKeyframeValue(value.replacing(rotationDegrees: Float($0))) }),
                   in: -180...180, step: 1)
                .accessibilityLabel("Keyframe Rotation")
                .accessibilityValue("\(Int((Double(model.selectedCalloutTransformAtPlayhead.decomposedRotation) * 180 / Double.pi).rounded())) degrees")
        }
    }

    // MARK: - Padded Background

    @ViewBuilder
    private var paddedBackgroundSection: some View {
        DisclosureGroup("Padded Background") {
            if model.project.paddedBackground != nil {
                Button("Choose Image…") {
                    showBackgroundImageImporter = true
                }
                .accessibilityHint("Import an image for the padded background")
                paddedBackgroundControls
                Button("Remove Background") {
                    model.removePaddedBackground()
                }
            } else {
                Button("Apply Gradient Background") {
                    model.applyPaddedBackground()
                }
                Button("Choose Image…") {
                    showBackgroundImageImporter = true
                }
            }
        }
    }

    @ViewBuilder
    private var paddedBackgroundControls: some View {
        // Always read from the model, not from a captured `preset` variable,
        // so the bindings reflect the current state even if the preset changes
        // during slider interaction.
        if model.project.paddedBackground != nil {
            Picker("Source", selection: Binding(
                get: { model.project.paddedBackground?.source ?? .gradient },
                set: { source in model.updatePaddedBackground { $0.source = source } })) {
                    Text("Gradient").tag(PaddedBackgroundSource.gradient)
                    Text("Image").tag(PaddedBackgroundSource.image)
                }

            HStack {
                Text("Inset")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { Double(model.project.paddedBackground?.insetMargin ?? 0) },
                    set: { value in model.updatePaddedBackground { $0.insetMargin = Float(value) } }),
                       in: 0...240, step: 1)
                    .accessibilityLabel("Inset")
                    .accessibilityValue("\(Int(model.project.paddedBackground?.insetMargin ?? 0))")
                Text("\(Int(model.project.paddedBackground?.insetMargin ?? 0))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack {
                Text("Corners")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { Double(model.project.paddedBackground?.cornerRadius ?? 0) },
                    set: { value in model.updatePaddedBackground { $0.cornerRadius = Float(value) } }),
                       in: 0...80, step: 1)
                    .accessibilityLabel("Corners")
                    .accessibilityValue("\(Int(model.project.paddedBackground?.cornerRadius ?? 0))")
                Text("\(Int(model.project.paddedBackground?.cornerRadius ?? 0))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack {
                Text("Shadow")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { Double(model.project.paddedBackground?.shadowOpacity ?? 0) },
                    set: { value in model.updatePaddedBackground { $0.shadowOpacity = Float(value) } }),
                       in: 0...1, step: 0.05)
                    .accessibilityLabel("Shadow")
                    .accessibilityValue(String(format: "%.0f%%", (model.project.paddedBackground?.shadowOpacity ?? 0) * 100))
            }
        }
    }

    // MARK: - Auto-Zoom Proposals

    @ViewBuilder
    private var autoZoomSection: some View {
        Button("Import Event Log…") {
            showEventLogImporter = true
        }
        if model.hasAutoZoomProposals {
            Button("Review Auto-Zoom Proposals") {
                showAutoZoomReview = true
            }
        }
    }
}

// MARK: - Auto-Zoom Review Sheet

struct AutoZoomReviewSheet: View {
    @Bindable var model: EditorModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Auto-Zoom Proposals")
                .font(.headline)

            if model.autoZoomProposals.isEmpty {
                Text("No proposals generated from the event log.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(model.autoZoomProposals) { proposal in
                        proposalRow(proposal)
                    }
                }
            }

            HStack {
                Button("Close") {
                    isPresented = false
                }
                Spacer()
                Button("Apply All") {
                    model.applyAllAutoZoomProposals()
                    isPresented = false
                }
                .disabled(model.autoZoomProposals.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    @ViewBuilder
    private func proposalRow(_ proposal: ZoomPanProposal) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(proposal.clickCount) clicks")
                    .font(.body)
                Text("at \(String(format: "%.1f", proposal.timeRange.start.seconds))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply") {
                model.applyAutoZoomProposal(proposal)
            }
            Button("Skip") {
                model.skipAutoZoomProposal(proposal)
            }
        }
    }
}
