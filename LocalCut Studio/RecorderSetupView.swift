import SwiftUI
import LocalCutCore
import LocalCutPlatform

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
    @State private var includeRegionCapture = false
    @State private var selectedRegion: CaptureRegion?
    @State private var isPickingRegion = false
    @State private var isLoadingSources = true
    @State private var loadError: String?
    @State private var countdownDuration = 3
    @State private var selectedPiPPresetID: String? = PiPPreset.standardPresets.first?.id

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
                    .onChange(of: selectedScreenID) { _, _ in
                        selectedRegion = nil
                        if !canPickRegion { includeRegionCapture = false }
                    }
                    Toggle("Region capture", isOn: $includeRegionCapture)
                        .disabled(!canPickRegion)
                    HStack {
                        Button {
                            pickRegion()
                        } label: {
                            Label(regionButtonTitle, systemImage: "crop")
                        }
                        .disabled(!includeRegionCapture || !canPickRegion || isPickingRegion)
                        .accessibilityHint("Draw a rectangle on screen to capture only that area")
                        if let selectedRegion, includeRegionCapture {
                            Text("\(selectedRegion.outputWidth) x \(selectedRegion.outputHeight)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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

                if includeScreen && includeWebcam {
                    Section("Picture in Picture") {
                        Picker("Layout", selection: $selectedPiPPresetID) {
                            Text("None").tag(Optional<String>.none)
                            ForEach(PiPPreset.standardPresets) { preset in
                                Text(preset.displayName).tag(Optional(preset.id))
                            }
                        }
                    }
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

                Section("Countdown") {
                    Picker("Delay", selection: $countdownDuration) {
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                }

                Section("Replay Buffer") {
                    Toggle("Enable replay buffer", isOn: $model.replayBufferEnabled)
                    Picker("Duration", selection: $model.replayBufferDuration) {
                        ForEach(ReplayBufferConfig.DurationOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .disabled(!model.replayBufferEnabled)
                    Text("Saves the last N seconds as a clip while recording continues.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Controls") {
                    Toggle("Hide floating controls while recording",
                           isOn: $model.hideFloatingPanelWhileRecording)
                }

                Section("Storage") {
                    HStack {
                        Text(model.recordingsFolderAccessURL?.lastPathComponent ?? "No folder selected")
                            .foregroundStyle(model.recordingsFolderAccessURL == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { _ = model.chooseRecordingsFolder() }
                            .accessibilityLabel("Choose recordings folder")
                            .accessibilityHint("Select where recordings are saved")
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
                .font(.headline)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canStart: Bool {
        if isLoadingSources || model.isRecording || model.isStartingRecording || model.isStoppingRecording { return false }
        if includeScreen && selectedScreenID != nil {
            return !includeRegionCapture || selectedRegion != nil
        }
        if includeWebcam && selectedWebcamID != nil { return true }
        if includeMicrophone && selectedMicrophoneID != nil { return true }
        return false
    }

    private var selectedScreenOption: CaptureSourceOption? {
        screenOptions.first(where: { $0.id == selectedScreenID })
    }

    private var canPickRegion: Bool {
        guard includeScreen, let target = selectedScreenOption?.target else { return false }
        if case .display = target { return true }
        return false
    }

    private var regionButtonTitle: String {
        selectedRegion == nil ? "Select Region…" : "Change Region…"
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
        var target = includeScreen ? selectedScreenOption?.target : nil
        var captureRegion: CaptureRegion?
        if includeRegionCapture,
           let selectedRegion,
           case .display(let displayID, _, _) = target,
           selectedRegion.displayID == displayID {
            target = .display(
                displayID: displayID,
                width: selectedRegion.outputWidth,
                height: selectedRegion.outputHeight)
            captureRegion = selectedRegion
        }
        let webcam = includeWebcam ? selectedWebcamID : nil
        let mic = includeMicrophone ? selectedMicrophoneID : nil
        let pipPreset = target != nil && webcam != nil
            ? PiPPreset.standardPresets.first(where: { $0.id == selectedPiPPresetID })
            : nil
        Task { [weak model] in
            await model?.startRecordingWithCountdown(
                countdownSeconds: countdownDuration,
                target: target,
                // Only capture system audio when a screen target actually
                // exists; otherwise its writer would never receive data.
                includeSystemAudio: target != nil && includeSystemAudio,
                webcamDeviceID: webcam,
                microphoneDeviceID: mic,
                captureRegion: captureRegion,
                pipPreset: pipPreset)
        }
    }

    private func pickRegion() {
        guard let target = selectedScreenOption?.target else { return }
        isPickingRegion = true
        Task {
            let region = await RegionCapturePicker.pickRegion(for: target)
            selectedRegion = region ?? selectedRegion
            isPickingRegion = false
        }
    }
}
