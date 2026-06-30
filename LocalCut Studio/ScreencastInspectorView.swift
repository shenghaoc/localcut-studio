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
                }
            }
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

        if let calloutID = model.selectedCalloutID,
           let callout = model.callout(for: calloutID) {
            calloutParameterEditor(callout)
        }
    }

    /// Creates a binding that dynamically fetches the latest callout from the
    /// model by ID, avoiding stale captures during rapid slider updates.
    private func calloutBinding(for callout: CalloutClip) -> Binding<CalloutClip> {
        Binding(
            get: { model.callout(for: callout.id) ?? callout },
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
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.arrowStyle.strokeWidth) },
                set: { var c = binding.wrappedValue; c.arrowStyle.strokeWidth = Float($0); binding.wrappedValue = c }),
                   in: 1...10, step: 1)
        }
    }

    @ViewBuilder
    private func boxEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        HStack {
            Text("Corner Radius")
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.boxStyle.cornerRadius) },
                set: { var c = binding.wrappedValue; c.boxStyle.cornerRadius = Float($0); binding.wrappedValue = c }),
                   in: 0...30, step: 1)
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
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.spotlightStyle.radius) },
                set: { var c = binding.wrappedValue; c.spotlightStyle.radius = Float($0); binding.wrappedValue = c }),
                   in: 0.02...0.5, step: 0.01)
        }
        HStack {
            Text("Dim")
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.spotlightStyle.dimOpacity) },
                set: { var c = binding.wrappedValue; c.spotlightStyle.dimOpacity = Float($0); binding.wrappedValue = c }),
                   in: 0...1, step: 0.05)
        }
    }

    @ViewBuilder
    private func blurRegionEditor(_ callout: CalloutClip) -> some View {
        let binding = calloutBinding(for: callout)
        HStack {
            Text("Blur")
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.blurRegionStyle.blurRadius) },
                set: { var c = binding.wrappedValue; c.blurRegionStyle.blurRadius = Float($0); binding.wrappedValue = c }),
                   in: 1...50, step: 1)
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
                          format: .number.precision(.fractionLength(0)))
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Position Y") {
                TextField("Y", value: Binding(
                    get: { Double(binding.wrappedValue.positionOffset.height) },
                    set: { var c = binding.wrappedValue; c.positionOffset.height = CGFloat($0); binding.wrappedValue = c }),
                          format: .number.precision(.fractionLength(0)))
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Scale")
                Slider(value: Binding(
                    get: { CGFloat(binding.wrappedValue.scale) },
                    set: { var c = binding.wrappedValue; c.scale = Float($0); binding.wrappedValue = c }),
                       in: 0.1...4, step: 0.05)
                Text(String(format: "%.2fx", binding.wrappedValue.scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Rotation")
                Slider(value: Binding(
                    get: { CGFloat(Double(binding.wrappedValue.rotation) * 180 / Double.pi) },
                    set: {
                        var c = binding.wrappedValue
                        c.rotation = Float(Double($0) * Double.pi / 180)
                        binding.wrappedValue = c
                    }),
                       in: -180...180, step: 1)
                Text("\(Int(Double(binding.wrappedValue.rotation) * 180 / Double.pi)) deg")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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
            Slider(value: Binding(
                get: { Double(model.selectedCalloutTransformAtPlayhead.decomposedScale) },
                set: { model.updateSelectedCalloutTransformKeyframeValue(value.replacing(scale: Float($0))) }),
                   in: 0.1...4, step: 0.05)
        }
        HStack {
            Text("Keyframe Rotation")
            Slider(value: Binding(
                get: { Double(model.selectedCalloutTransformAtPlayhead.decomposedRotation) * 180 / Double.pi },
                set: { model.updateSelectedCalloutTransformKeyframeValue(value.replacing(rotationDegrees: Float($0))) }),
                   in: -180...180, step: 1)
        }
    }

    // MARK: - Padded Background

    @ViewBuilder
    private var paddedBackgroundSection: some View {
        DisclosureGroup("Padded Background") {
            if model.project.paddedBackground != nil {
                Button("Choose Image...") {
                    showBackgroundImageImporter = true
                }
                paddedBackgroundControls
                Button("Remove Background") {
                    model.removePaddedBackground()
                }
            } else {
                Button("Apply Gradient Background") {
                    model.applyPaddedBackground()
                }
                Button("Choose Image...") {
                    showBackgroundImageImporter = true
                }
            }
        }
    }

    @ViewBuilder
    private var paddedBackgroundControls: some View {
        if let preset = model.project.paddedBackground {
            Picker("Source", selection: Binding(
                get: { preset.source },
                set: { source in model.updatePaddedBackground { $0.source = source } })) {
                    Text("Gradient").tag(PaddedBackgroundSource.gradient)
                    Text("Image").tag(PaddedBackgroundSource.image)
                }

            HStack {
                Text("Inset")
                Slider(value: Binding(
                    get: { Double(model.project.paddedBackground?.insetMargin ?? preset.insetMargin) },
                    set: { value in model.updatePaddedBackground { $0.insetMargin = Float(value) } }),
                       in: 0...240, step: 1)
                Text("\(Int(model.project.paddedBackground?.insetMargin ?? preset.insetMargin))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Corners")
                Slider(value: Binding(
                    get: { Double(model.project.paddedBackground?.cornerRadius ?? preset.cornerRadius) },
                    set: { value in model.updatePaddedBackground { $0.cornerRadius = Float(value) } }),
                       in: 0...80, step: 1)
                Text("\(Int(model.project.paddedBackground?.cornerRadius ?? preset.cornerRadius))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Shadow")
                Slider(value: Binding(
                    get: { Double(model.project.paddedBackground?.shadowOpacity ?? preset.shadowOpacity) },
                    set: { value in model.updatePaddedBackground { $0.shadowOpacity = Float(value) } }),
                       in: 0...1, step: 0.05)
            }
        }
    }

    // MARK: - Auto-Zoom Proposals

    @ViewBuilder
    private var autoZoomSection: some View {
        Button("Import Event Log...") {
            showEventLogImporter = true
        }
        if model.hasAutoZoomProposals {
            Button("Review Auto-Zoom Proposals") {
                showAutoZoomReview = true
            }
        }
    }
}

private extension Transform2D {
    func replacing(translateX: Float? = nil,
                   translateY: Float? = nil,
                   scale: Float? = nil,
                   rotationDegrees: Float? = nil) -> Transform2D {
        Transform2D(
            translateX: translateX ?? tx,
            translateY: translateY ?? ty,
            scale: scale ?? decomposedScale,
            rotation: rotationDegrees.map { $0 * Float.pi / 180 } ?? decomposedRotation)
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
