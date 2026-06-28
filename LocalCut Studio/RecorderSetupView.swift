import SwiftUI
import LocalCutCore

struct RecorderSetupView: View {
    @Bindable var model: EditorModel

    @State private var screenOptions: [CaptureSourceOption] = []
    @State private var webcamOptions: [CaptureDeviceOption] = []
    @State private var microphoneOptions: [CaptureDeviceOption] = []
    @State private var selectedScreenID: String?
    @State private var selectedWebcamID: String?
    @State private var selectedMicrophoneID: String?
    @State private var includeScreen = true
    @State private var includeSystemAudio = false
    @State private var includeWebcam = false
    @State private var includeMicrophone = false
    @State private var isLoadingSources = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section("Screen") {
                    Toggle("Record screen, window, or app", isOn: $includeScreen)
                    Picker("Source", selection: $selectedScreenID) {
                        ForEach(screenOptions) { option in
                            Text(option.title).tag(Optional(option.id))
                        }
                    }
                    .disabled(!includeScreen || screenOptions.isEmpty)
                    Toggle("System audio", isOn: $includeSystemAudio)
                        .disabled(!includeScreen || !CaptureSourceCatalog.isSystemAudioAvailable)
                    if !CaptureSourceCatalog.isSystemAudioAvailable {
                        Text("System audio capture requires macOS 13+ with Apple Silicon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Camera") {
                    Toggle("Webcam", isOn: $includeWebcam)
                    Picker("Camera", selection: $selectedWebcamID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(webcamOptions) { device in
                            Text(device.title).tag(Optional(device.id))
                        }
                    }
                    .disabled(!includeWebcam || webcamOptions.isEmpty)
                }

                Section("Audio") {
                    Toggle("Microphone", isOn: $includeMicrophone)
                    Picker("Input", selection: $selectedMicrophoneID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(microphoneOptions) { device in
                            Text(device.title).tag(Optional(device.id))
                        }
                    }
                    .disabled(!includeMicrophone || microphoneOptions.isEmpty)
                }

                Section("Storage") {
                    HStack {
                        Text(model.recordingsFolderAccessURL?.lastPathComponent ?? "No folder selected")
                            .foregroundStyle(model.recordingsFolderAccessURL == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { _ = model.chooseRecordingsFolder() }
                    }
                }
            }
            .formStyle(.grouped)

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()
            footer
        }
        .frame(width: 440, height: 560)
        .task { await loadSources() }
    }

    private var header: some View {
        HStack {
            Text("Recorder")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                model.isRecorderPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close recorder")
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if isLoadingSources {
                ProgressView()
                    .controlSize(.small)
                Text("Loading sources…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                model.isRecorderPresented = false
            }
            Button {
                start()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
        }
        .padding(20)
    }

    private var canStart: Bool {
        if isLoadingSources || model.isRecording || model.isStartingRecording || model.isStoppingRecording { return false }
        if includeScreen && selectedScreenID != nil { return true }
        if includeWebcam && selectedWebcamID != nil { return true }
        if includeMicrophone && selectedMicrophoneID != nil { return true }
        return false
    }

    private func loadSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }
        do {
            screenOptions = try await CaptureSourceCatalog.screenOptions()
            selectedScreenID = screenOptions.first?.id
            webcamOptions = CaptureSourceCatalog.webcamOptions()
            selectedWebcamID = webcamOptions.first?.id
            microphoneOptions = CaptureSourceCatalog.microphoneOptions()
            selectedMicrophoneID = microphoneOptions.first?.id
            loadError = nil
        } catch {
            includeScreen = false
            loadError = error.localizedDescription
            webcamOptions = CaptureSourceCatalog.webcamOptions()
            selectedWebcamID = webcamOptions.first?.id
            microphoneOptions = CaptureSourceCatalog.microphoneOptions()
            selectedMicrophoneID = microphoneOptions.first?.id
        }
    }

    private func start() {
        let target = includeScreen
            ? screenOptions.first(where: { $0.id == selectedScreenID })?.target
            : nil
        let webcam = includeWebcam ? selectedWebcamID : nil
        let mic = includeMicrophone ? selectedMicrophoneID : nil
        Task {
            await model.startRecording(
                target: target,
                // Only capture system audio when a screen target actually
                // exists; otherwise its writer would never receive data.
                includeSystemAudio: target != nil && includeSystemAudio,
                webcamDeviceID: webcam,
                microphoneDeviceID: mic)
        }
    }
}
