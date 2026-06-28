import SwiftUI

/// SwiftUI content displayed inside the floating recorder control panel.
struct RecorderFloatingPanelContent: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            // Recording indicator.
            Circle()
                .fill(model.isRecording ? .red : .orange)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            // Elapsed time.
            Text(formatElapsed(model.recordingElapsedSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Recording elapsed \(formatElapsed(model.recordingElapsedSeconds))")

            Spacer()

            // Pause / Resume.
            if model.isPaused {
                Button {
                    Task { await model.resumeRecording() }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Resume recording")
                .accessibilityLabel("Resume recording")
            } else if model.isRecording {
                Button {
                    Task { await model.pauseRecording() }
                } label: {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.borderless)
                .help("Pause recording")
                .accessibilityLabel("Pause recording")
            }

            // Stop.
            Button {
                model.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        }
        .padding(12)
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
