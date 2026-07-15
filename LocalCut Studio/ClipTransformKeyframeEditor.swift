import SwiftUI
import CoreMedia
import LocalCutCore
import LocalCutDomain

struct ClipTransformKeyframeEditor: View {
    @Bindable var model: EditorModel

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

            HStack(spacing: 8) {
                Button {
                    model.seekToPreviousSelectedClipTransformKeyframe()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("Previous keyframe")
                .accessibilityLabel("Previous clip transform keyframe")

                Button {
                    model.addOrUpdateSelectedClipTransformKeyframe()
                } label: {
                    Label(hasKeyframe ? "Update" : "Add",
                          systemImage: hasKeyframe ? "diamond.fill" : "plus.diamond.fill")
                }
                .disabled(model.selectedClipTransformLocalPlayheadTime == nil)
                .help(hasKeyframe ? "Update clip transform keyframe" : "Add clip transform keyframe")
                .accessibilityLabel(hasKeyframe ? "Update clip transform keyframe" : "Add clip transform keyframe")

                Button(role: .destructive) {
                    model.removeSelectedClipTransformKeyframe()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove keyframe")
                .accessibilityLabel("Remove clip transform keyframe")
                .disabled(!hasKeyframe)

                Button {
                    model.seekToNextSelectedClipTransformKeyframe()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .help("Next keyframe")
                .accessibilityLabel("Next clip transform keyframe")
            }
            .controlSize(.small)

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
                .frame(minWidth: 72)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Pan Y") {
            TextField("Y", value: Binding(
                get: { Double(model.selectedClipTransformAtPlayhead.ty) },
                set: { model.updateSelectedClipTransformKeyframeValue(value.replacing(translateY: Float($0))) }),
                      format: .number.precision(.fractionLength(3)))
                .frame(minWidth: 72)
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
