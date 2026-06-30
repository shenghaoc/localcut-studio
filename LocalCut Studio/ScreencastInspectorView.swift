import SwiftUI
import CoreMedia
import LocalCutCore

/// Inspector section for Phase 43 screencast post-pack tools: zoom-n-pan
/// presets, auto-zoom proposals, callouts, and padded background.
struct ScreencastInspectorView: View {
    @Bindable var model: EditorModel
    @State private var showAutoZoomReview = false

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

            Button("Remove Callout", role: .destructive) {
                model.removeCallout(id: callout.id)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func arrowEditor(_ callout: CalloutClip) -> some View {
        let binding = Binding(
            get: { callout },
            set: { model.updateCallout($0) })
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
        let binding = Binding(
            get: { callout },
            set: { model.updateCallout($0) })
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
        let binding = Binding(
            get: { callout },
            set: { model.updateCallout($0) })
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
        let binding = Binding(
            get: { callout },
            set: { model.updateCallout($0) })
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
        let binding = Binding(
            get: { callout },
            set: { model.updateCallout($0) })
        HStack {
            Text("Blur")
            Slider(value: Binding(
                get: { CGFloat(binding.wrappedValue.blurRegionStyle.blurRadius) },
                set: { var c = binding.wrappedValue; c.blurRegionStyle.blurRadius = Float($0); binding.wrappedValue = c }),
                   in: 1...50, step: 1)
        }
    }

    // MARK: - Padded Background

    @ViewBuilder
    private var paddedBackgroundSection: some View {
        DisclosureGroup("Padded Background") {
            if model.project.paddedBackground != nil {
                Button("Remove Background") {
                    model.removePaddedBackground()
                }
            } else {
                Button("Apply Gradient Background") {
                    model.applyPaddedBackground()
                }
            }
        }
    }

    // MARK: - Auto-Zoom Proposals

    @ViewBuilder
    private var autoZoomSection: some View {
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
