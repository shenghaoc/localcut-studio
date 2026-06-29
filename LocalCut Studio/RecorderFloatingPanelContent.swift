import SwiftUI

/// SwiftUI content displayed inside the floating recorder control panel.
struct RecorderFloatingPanelContent: View {
    @Bindable var model: EditorModel
    @State private var screenOptions: [CaptureSourceOption] = []
    @State private var showSourcePicker = false

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
                .accessibilityLabel("\(model.isPaused ? "Paused" : "Recording") elapsed \(formatElapsed(model.recordingElapsedSeconds))")

            Spacer()

            // Source switcher (only while actively recording).
            if model.isRecording && !screenOptions.isEmpty {
                Button {
                    showSourcePicker.toggle()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Switch capture source")
                .accessibilityLabel("Switch capture source")
                .popover(isPresented: $showSourcePicker) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Switch Source")
                            .font(.caption.weight(.semibold))
                            .padding(.bottom, 4)
                        ForEach(screenOptions) { option in
                            Button(option.title) {
                                showSourcePicker = false
                                Task { await model.switchCaptureSource(to: option.target) }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                        }
                    }
                    .padding(8)
                    .frame(minWidth: 160)
                }
            }

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
        .task { await loadScreenSources() }
    }

    private func loadScreenSources() async {
        do {
            screenOptions = try await CaptureSourceCatalog.screenOptions()
        } catch {
            screenOptions = []
        }
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
