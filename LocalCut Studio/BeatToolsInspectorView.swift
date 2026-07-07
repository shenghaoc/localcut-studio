import SwiftUI
import LocalCutCore

/// Default values for beat tools parameters, used by both the model and the
/// inspector reset actions to prevent drift.
enum BeatToolsDefaults {
    static let offsetSeconds: Double = 0
    static let alignWindowSeconds: Double = 0.15
}

struct BeatToolsInspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Beat Tools") {
            if let source = model.selectedBeatSource {
                LabeledContent("Source") {
                    Text(source.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.name)
                }
                if let analysis = model.beatAnalyses[source.id] {
                    LabeledContent("Tempo", value: "\(Int(analysis.tempoBPM.rounded())) BPM")
                    LabeledContent("Beats", value: "\(analysis.beatTimes.count)")
                    LabeledContent("Confidence", value: "\(Int(analysis.confidence * 100))%")
                }
            } else {
                Text("Select an audio source or clip.")
                    .foregroundStyle(.secondary)
            }

            Button {
                model.analyzeBeatsForSelection()
            } label: {
                Label("Analyse Beats", systemImage: "waveform.path.ecg")
            }
            .disabled(!model.canAnalyzeBeatsForSelection)
            .help("Analyse the selected audio source and cache beat markers.")
            .accessibilityHint("Analyse the selected audio source and cache beat markers.")

            Toggle("Show Beat Markers", isOn: $model.showBeatMarkers)
                .disabled(model.beatAnalyses.isEmpty)
                .help("Display beat markers on the timeline ruler")

            Toggle("Snap to Beats", isOn: $model.snapToBeats)
                .disabled(model.beatAnalyses.isEmpty)
                .help("Snap timeline edits to detected beat positions")

            LabeledSliderRow(
                label: "Offset",
                spokenLabel: "Beat Offset",
                display: "\(Int(model.beatOffsetSeconds * 1000)) ms",
                spokenValue: "\(Int(model.beatOffsetSeconds * 1000)) milliseconds",
                value: $model.beatOffsetSeconds,
                range: -0.2...0.2,
                step: 0.005,
                resetAction: { model.beatOffsetSeconds = BeatToolsDefaults.offsetSeconds })
            .disabled(model.beatAnalyses.isEmpty)

            LabeledSliderRow(
                label: "Align Window",
                spokenLabel: "Beat Alignment Window",
                display: "\(Int(model.beatAlignWindowSeconds * 1000)) ms",
                spokenValue: "\(Int(model.beatAlignWindowSeconds * 1000)) milliseconds",
                value: $model.beatAlignWindowSeconds,
                range: 0.02...0.5,
                step: 0.01,
                resetAction: { model.beatAlignWindowSeconds = BeatToolsDefaults.alignWindowSeconds })

            HStack {
                Button {
                    model.cutSelectedClipAtBeats()
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .disabled(!model.canCutSelectedClipAtBeats)
                .help("Split the selected clip at beat markers in its range.")

                Button {
                    model.alignSelectedClipToBeat()
                } label: {
                    Label("Align", systemImage: "arrow.left.and.right")
                }
                .disabled(!model.canAlignSelectedClipToBeat)
                .help("Move the selected clip start to the nearest beat within the align window.")
            }
            .controlSize(.small)
        }
    }
}
