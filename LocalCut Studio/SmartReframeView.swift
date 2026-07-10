import SwiftUI
import LocalCutCore

// MARK: - Smart Reframe Inspector (Phase 33)

/// Inspector section for Smart Reframe analysis and review.
struct SmartReframeInspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Smart Reframe") {
            targetAspectPicker
            analysisControls
            if model.isReframeAnalyzing {
                progressSection
            }
            if let proposal = model.reframeProposal {
                proposalSummary(proposal)
                actionButtons
            }
            if !model.reframeProgressMessage.isEmpty && !model.isReframeAnalyzing {
                Text(model.reframeProgressMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Target aspect picker

    private var targetAspectPicker: some View {
        Picker("Target Aspect", selection: $model.reframeOptions.targetAspectRatio) {
            Text("9:16 Vertical").tag(Float(9.0 / 16.0))
            Text("1:1 Square").tag(Float(1.0))
            Text("4:5 Portrait").tag(Float(4.0 / 5.0))
            Text("16:9 Widescreen").tag(Float(16.0 / 9.0))
        }
    }

    // MARK: - Analysis controls

    private var analysisControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                LabeledContent("Analysis FPS") {
                    Slider(
                        value: $model.reframeOptions.analysisFPS,
                        in: 0.5...5.0,
                        step: 0.5
                    ) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("0.5").font(.caption2)
                    } maximumValueLabel: {
                        Text("5").font(.caption2)
                    }
                    .frame(width: 100)
                    Text("\(model.reframeOptions.analysisFPS, specifier: "%.1f")")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 28)
                }
            }

            HStack {
                LabeledContent("Velocity") {
                    Text("\(model.reframeOptions.velocityBound, specifier: "%.2f")")
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            HStack {
                LabeledContent("Acceleration") {
                    Text("\(model.reframeOptions.accelerationBound, specifier: "%.2f")")
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            Button {
                model.runSmartReframeAnalysis()
            } label: {
                Label("Analyze", systemImage: "viewfinder.rectangular")
            }
            .disabled(model.isReframeAnalyzing || model.selectedClip == nil)
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView()
                .progressViewStyle(.linear)
            HStack {
                Text(model.reframeProgressMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.cancelSmartReframeAnalysis()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Proposal summary

    private func proposalSummary(_ proposal: ReframeProposal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Keyframes", value: "\(proposal.keyframes.count)")
            LabeledContent("Frames Analyzed", value: "\(proposal.framesAnalyzed)")
            LabeledContent("Detection", value: proposal.detectionMode.rawValue.capitalized)
            if !proposal.shotBoundaries.isEmpty {
                LabeledContent("Shot Cuts", value: "\(proposal.shotBoundaries.count)")
            }
            if !proposal.warnings.isEmpty {
                ForEach(proposal.warnings.indices, id: \.self) { i in
                    warningView(proposal.warnings[i])
                }
            }
            Toggle("Show Overlay", isOn: $model.showReframeOverlay)
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack {
            Button {
                model.applySmartReframeProposal()
            } label: {
                Label("Apply", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                model.discardSmartReframeProposal()
            } label: {
                Label("Discard", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Warning views

    @ViewBuilder
    private func warningView(_ warning: ReframeWarning) -> some View {
        switch warning {
        case .safeZoneComplianceBelowThreshold(let compliance, let scale):
            Label(
                "Safe zone: \(Int(compliance * 100))% at \(String(format: "%.0f%%", scale * 100)) scale",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        case .veryShortClip(let duration):
            Label(
                "Very short clip (\(String(format: "%.2f", duration))s): start/end keyframes only",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        case .noSubjectDetected:
            Label("No subject detected in some frames", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Reframe Overlay

/// SwiftUI overlay drawn over `AVPlayerView` showing the target crop rectangle
/// and action-safe zone at the current playhead.
struct SmartReframeOverlayView: View {
    let targetAspectRatio: Float
    let currentTransform: Transform2D?
    let renderSize: CGSize
    let containerSize: CGSize
    let actionSafeHalfExtent: Float

    var body: some View {
        Canvas { context, size in
            guard let transform = currentTransform else { return }

            let canvasRect = PreviewCanvasGeometry.canvasRect(
                container: size,
                renderSize: renderSize
            )
            guard canvasRect.width > 0, canvasRect.height > 0 else { return }

            let scale = CGFloat(transform.decomposedScale)
            let tx = CGFloat(transform.tx)
            let ty = CGFloat(transform.ty)

            // Crop rectangle: the target aspect region
            let cropWidth = canvasRect.width / scale
            let cropHeight = canvasRect.height / scale
            let cropX = canvasRect.midX - cropWidth / 2 - tx * canvasRect.width / scale
            let cropY = canvasRect.midY - cropHeight / 2 - ty * canvasRect.height / scale
            let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

            // Draw crop rectangle
            context.stroke(
                Path(cropRect),
                with: .color(.white.opacity(0.8)),
                lineWidth: 2
            )

            // Action-safe inner rectangle
            let safeInset = CGFloat(actionSafeHalfExtent) * min(cropWidth, cropHeight)
            let safeRect = cropRect.insetBy(
                dx: cropWidth / 2 - safeInset,
                dy: cropHeight / 2 - safeInset
            )
            context.stroke(
                Path(safeRect),
                with: .color(.yellow.opacity(0.6)),
                style: StrokeStyle(lineWidth: 1, dash: [6, 4])
            )

            // Dim regions outside crop
            let fullPath = Path(CGRect(origin: .zero, size: size))
            let cropPath = Path(cropRect)
            let dimPath = fullPath.subtracting(cropPath)
            context.fill(dimPath, with: .color(.black.opacity(0.4)))
        }
    }
}
