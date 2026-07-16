import SwiftUI
import CoreMedia
import LocalCutCore
import LocalCutDomain

struct ClipTransformKeyframeEditor: View {
    @Bindable var model: EditorModel
    @ScaledMetric(relativeTo: .body) private var numericFieldWidth: CGFloat = 72

    var body: some View {
        let hasKeyframe = model.selectedClipTransformKeyframeAtPlayhead != nil

        DisclosureGroup("Clip Transform Keyframes") {
            LabeledContent("Local Time") {
                Text(model.selectedClipTransformLocalPlayheadTime.map { TimeFormatting.timecode($0.seconds) } ?? "--:--")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Count") {
                Text("\(model.selectedClipTransformKeyframeCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            KeyframeNavBar(
                keyframeKind: "clip transform",
                canGoToPrevious: true,
                canAddOrUpdate: model.selectedClipTransformLocalPlayheadTime != nil,
                canRemove: hasKeyframe,
                canGoToNext: true,
                hasKeyframeAtPlayhead: hasKeyframe,
                onPrevious: { model.seekToPreviousSelectedClipTransformKeyframe() },
                onAddOrUpdate: { model.addOrUpdateSelectedClipTransformKeyframe() },
                onRemove: { model.removeSelectedClipTransformKeyframe() },
                onNext: { model.seekToNextSelectedClipTransformKeyframe() }
            )

            if hasKeyframe {
                keyframeValueEditor
            }

            if model.selectedClipTransformKeyframeCount > 0, let clipID = model.selectedClipID {
                Button("Clear All Keyframes", role: .destructive) {
                    model.clearClipTransformKeyframes(clipID: clipID)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var keyframeValueEditor: some View {
        let value = model.selectedClipTransformAtPlayhead
        LabeledContent("Pan X") {
            TextField("X", value: Binding(
                get: { Double(model.selectedClipTransformAtPlayhead.tx) },
                set: { model.updateSelectedClipTransformKeyframeValue(value.replacing(translateX: Float($0))) }),
                      format: .number.precision(.fractionLength(3)))
                .frame(width: numericFieldWidth)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Pan Y") {
            TextField("Y", value: Binding(
                get: { Double(model.selectedClipTransformAtPlayhead.ty) },
                set: { model.updateSelectedClipTransformKeyframeValue(value.replacing(translateY: Float($0))) }),
                      format: .number.precision(.fractionLength(3)))
                .frame(width: numericFieldWidth)
                .multilineTextAlignment(.trailing)
        }
        HStack {
            Text("Scale")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(model.selectedClipTransformAtPlayhead.decomposedScale) },
                set: { model.updateSelectedClipTransformKeyframeValue(value.replacing(scale: Float($0))) }),
                   in: 0.25...4, step: 0.05)
                .accessibilityLabel("Scale")
                .accessibilityValue("\(Int((value.decomposedScale * 100).rounded())) percent")
            Text(String(format: "%.2fx", model.selectedClipTransformAtPlayhead.decomposedScale))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        HStack {
            Text("Rotation")
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(model.selectedClipTransformAtPlayhead.decomposedRotation) * 180 / Double.pi },
                set: { model.updateSelectedClipTransformKeyframeValue(value.replacing(rotationDegrees: Float($0))) }),
                   in: -180...180, step: 1)
                .accessibilityLabel("Rotation")
                .accessibilityValue("\(Int((Double(value.decomposedRotation) * 180 / Double.pi).rounded())) degrees")
            Text("\(Int(Double(model.selectedClipTransformAtPlayhead.decomposedRotation) * 180 / Double.pi)) deg")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}
