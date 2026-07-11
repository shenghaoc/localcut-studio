import SwiftUI
import LocalCutCore
import LocalCutPlatform

/// SwiftUI content displayed inside the floating recorder control panel.
struct RecorderFloatingPanelContent: View {
    @Bindable var model: EditorModel
    @State private var screenOptions: [CaptureSourceOption] = []
    @State private var sourceLoadFailed = false

    var body: some View {
        HStack(spacing: 12) {
            // Recording indicator.
            Circle()
                .fill(model.isRecording ? .red : .orange)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            // Elapsed time.
            PanelRecordingElapsedView(model: model)
            sourceIndicator
            if model.recordingIncludesMicrophone {
                PanelMicLevelMeterView(model: model)
            }

            Spacer()

            // Source switcher.
            Menu {
                if sourceLoadFailed {
                    Text("Sources unavailable")
                } else if screenOptions.isEmpty {
                    Text("No screen sources")
                } else {
                    ForEach(screenOptions) { [weak model] option in
                        Button {
                            Task { await model?.switchCaptureSource(to: option.target) }
                        } label: {
                            Label(option.title, systemImage: iconName(for: option.target))
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .disabled(!model.isRecording || model.isPausingRecording || model.isStartingRecording || screenOptions.isEmpty)
            .help(sourceSwitchHelp)
            .accessibilityLabel("Switch capture source")

            // Pause / Resume.
            if model.isPaused {
                Button { [weak model] in
                    Task { await model?.resumeRecording() }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.isStartingRecording || model.isStoppingRecording)
                .help("Resume recording")
                .accessibilityLabel("Resume recording")
            } else if model.isRecording {
                Button { [weak model] in
                    Task { await model?.pauseRecording() }
                } label: {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.isPausingRecording || model.isStoppingRecording)
                .help("Pause recording")
                .accessibilityLabel("Pause recording")
            }

            // Save replay (Phase 46).
            if model.isRecording && model.replayBufferManager != nil {
                Button {
                    model.saveReplayBuffer()
                } label: {
                    Image(systemName: "gobackward")
                }
                .buttonStyle(.borderless)
                .disabled(model.replaySaveInProgress || !model.replayBufferEnabled)
                .help("Save last \(model.replayBufferDuration.displayName)")
                .accessibilityLabel("Save replay")
            }

            // Stop.
            Button {
                model.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(model.isStartingRecording || model.isPausingRecording || model.isStoppingRecording)
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        }
        .padding(12)
        .task(id: model.isRecording) {
            guard model.isRecording else { return }
            await loadScreenSources()
        }
    }

    private func loadScreenSources() async {
        do {
            screenOptions = try await CaptureSourceCatalog.screenOptions()
            sourceLoadFailed = false
        } catch {
            screenOptions = []
            sourceLoadFailed = true
        }
    }

    private var sourceIndicator: some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.stack")
                .font(.caption2)
            Text("\(model.recordingSourceCount)")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .help("Recording sources")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.recordingSourceCount) recording source\(model.recordingSourceCount == 1 ? "" : "s")")
    }

    private var sourceSwitchHelp: String {
        if !model.isRecording { return "Start recording before switching sources" }
        if model.isPausingRecording || model.isStartingRecording { return "Finish the recording transition before switching sources" }
        if sourceLoadFailed { return "Screen sources are unavailable" }
        if screenOptions.isEmpty { return "No screen sources available" }
        return "Switch capture source"
    }

    private func iconName(for target: CaptureTarget) -> String {
        switch target {
        case .display:
            "display"
        case .window:
            "macwindow"
        case .application:
            "app"
        }
    }
}

/// Extracted view to isolate high-frequency observation of `model.recordingElapsedSeconds`.
private struct PanelRecordingElapsedView: View {
    let model: EditorModel

    var body: some View {
        let elapsed = formatElapsed(model.recordingElapsedSeconds)
        Text(elapsed)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(model.isPaused ? "Paused" : "Recording") elapsed \(elapsed)")
    }
}

/// Extracted view to isolate high-frequency observation of `model.recordingMicLevel`.
private struct PanelMicLevelMeterView: View {
    let model: EditorModel

    var body: some View {
        MicLevelMeter(level: model.recordingMicLevel)
            .frame(width: 36, height: 8)
            .help("Microphone level")
            .accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int(model.recordingMicLevel * 100)) percent")
    }
}

private struct MicLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.green)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, level))))
            }
        }
    }
}
