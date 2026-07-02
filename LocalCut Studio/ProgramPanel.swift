import SwiftUI
import LocalCutCore

// MARK: - Program panel

/// The Program Mode panel: sources, scenes, hotkeys, start/stop, budget
/// readout, and program monitor (sharing existing preview output).
struct ProgramPanel: View {
    @Bindable var model: EditorModel

    @State private var programState = ProgramPanelState()
    @State private var editingSceneDraft: SceneEditorDraft?

    private var scenes: [SceneDefinition] {
        model.project.sceneDoc.scenes
    }

    private var hotkeyConflicts: [String] {
        detectHotkeyConflicts(in: scenes)
    }

    private var canStart: Bool {
        !programState.isRunning
            && !programState.isStarting
            && !programState.isStopping
            && !programState.sources.isEmpty
            && !scenes.isEmpty
            && hotkeyConflicts.isEmpty
            && programState.capabilitySufficient
            && !programState.isBudgetExhausted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            budgetReadout

            Divider()

            sourcesSection

            Divider()

            scenesSection

            Divider()

            controlsSection
        }
        .padding()
        .frame(minWidth: 280)
        .onAppear {
            programState.refreshCapability()
        }
        .onDisappear {
            programState.teardownIfRunning()
        }
        .onKeyPress { press in
            guard programState.isRunning,
                  let char = press.characters.first.map(String.init),
                  let scene = scenes.first(where: { $0.hotkey == char }) else {
                return .ignored
            }
            programState.switchScene(to: scene.id)
            return .handled
        }
        .sheet(isPresented: isEditingScene) {
            if let draft = editingSceneDraft {
                SceneEditorSheet(
                    draft: Binding(
                        get: { editingSceneDraft ?? draft },
                        set: { editingSceneDraft = $0 }),
                    sources: programState.sources,
                    onSave: saveScene,
                    onDelete: draft.isNew ? nil : { deleteScene(draft.scene.id) },
                    onCancel: { editingSceneDraft = nil })
            }
        }
    }

    private var isEditingScene: Binding<Bool> {
        Binding(
            get: { editingSceneDraft != nil },
            set: { isPresented in
                if !isPresented { editingSceneDraft = nil }
            })
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.red)
            Text("Program Mode")
                .font(.headline)
            Spacer()
            if programState.isRunning {
                Label("LIVE", systemImage: "circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption.bold())
            }
        }
    }

    // MARK: - Budget readout

    private var budgetReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Encoder Budget")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack {
                Text("\(programState.activeVideoSourceCount) / \(programState.budgetMax) video sources active")
                    .font(.caption)
                Spacer()
                if programState.isBudgetExhausted {
                    Label("Exhausted", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            if !programState.capabilitySufficient {
                Label("Hardware insufficient for Program Mode",
                      systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sources")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await programState.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(programState.isRunning || programState.isRefreshingSources)
                .help("Refresh capture sources")
                .accessibilityLabel("Refresh capture sources")
            }

            if programState.sources.isEmpty {
                Text("Refresh to list available capture sources.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(programState.sources, id: \.id) { source in
                    HStack {
                        Image(systemName: sourceIcon(for: source.kind))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(source.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if source.kind.isVideo {
                            Text("\(source.width ?? 0)x\(source.height ?? 0)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scenes

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scenes")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    presentNewSceneEditor()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(programState.isRunning)
                .help("Add program scene")
                .accessibilityLabel("Add program scene")
            }

            if scenes.isEmpty {
                Text("No scenes defined")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(scenes) { scene in
                    sceneRow(scene)
                }
            }

            if !hotkeyConflicts.isEmpty {
                Label("Hotkey conflict: \(hotkeyConflicts.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    private func sceneRow(_ scene: SceneDefinition) -> some View {
        HStack {
            Circle()
                .fill(programState.currentSceneId == scene.id ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(scene.name)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(scene.layers.count) layer\(scene.layers.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let hotkey = scene.hotkey {
                Text(hotkey)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .cornerRadius(4)
            }
            Button {
                presentSceneEditor(scene)
            } label: {
                Image(systemName: "pencil")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(programState.isRunning)
            .help("Edit scene")
            .accessibilityLabel("Edit \(scene.name)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if programState.isRunning {
                programState.switchScene(to: scene.id)
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if programState.isRunning {
                    Button {
                        programState.stop(model: model)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        programState.start(model: model, scenes: scenes)
                    } label: {
                        Label("Start Program", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                }
            }

            if !programState.statusMessage.isEmpty {
                Text(programState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Editing

    private func presentNewSceneEditor() {
        let scene = SceneDefinition(name: "Scene \(scenes.count + 1)", layers: [])
        editingSceneDraft = SceneEditorDraft(scene: scene, isNew: true)
    }

    private func presentSceneEditor(_ scene: SceneDefinition) {
        editingSceneDraft = SceneEditorDraft(scene: scene, isNew: false)
    }

    private func saveScene(_ draft: SceneEditorDraft) {
        let scene = draft.normalizedScene
        if draft.isNew {
            model.addProgramScene(scene)
        } else {
            model.updateProgramScene(scene)
        }
        editingSceneDraft = nil
    }

    private func deleteScene(_ sceneID: UUID) {
        model.deleteProgramScene(id: sceneID)
        if programState.currentSceneId == sceneID {
            programState.currentSceneId = scenes.first?.id
        }
        editingSceneDraft = nil
    }

    // MARK: - Helpers

    private func sourceIcon(for kind: CaptureSourceKind) -> String {
        switch kind {
        case .display: "display"
        case .window: "macwindow"
        case .application: "app"
        case .webcam: "video"
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        }
    }
}

// MARK: - Scene editor

private struct SceneEditorDraft: Identifiable {
    let id = UUID()
    var scene: SceneDefinition
    var isNew: Bool

    var normalizedScene: SceneDefinition {
        var result = scene
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.name.isEmpty {
            result.name = "Scene"
        }
        result.hotkey = Self.normalizedHotkey(result.hotkey)
        return result
    }

    var canSave: Bool {
        !scene.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func normalizedHotkey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first).lowercased()
    }
}

private struct SceneEditorSheet: View {
    @Binding var draft: SceneEditorDraft

    let sources: [CaptureSourceDescriptor]
    let onSave: (SceneEditorDraft) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    private var videoSources: [CaptureSourceDescriptor] {
        sources.filter(\.kind.isVideo)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Scene") {
                    TextField("Name", text: $draft.scene.name)
                    TextField("Hotkey", text: hotkeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .help("Use one character. Duplicates are surfaced in the panel.")
                }

                Section("Layers") {
                    if draft.scene.layers.isEmpty {
                        Text("No layers")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($draft.scene.layers) { $layer in
                            SceneLayerEditorRow(
                                layer: $layer,
                                sources: sources,
                                onDelete: { removeLayer(id: layer.id) })
                        }
                    }

                    Menu {
                        if videoSources.isEmpty {
                            Text("No video sources")
                        } else {
                            ForEach(videoSources, id: \.id) { source in
                                Button(source.displayName) {
                                    addSourceLayer(source)
                                }
                            }
                        }
                        Divider()
                        Button("Colour Layer") {
                            addColourLayer()
                        }
                    } label: {
                        Label("Add Layer", systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                }
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                Button("Save") {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
            }
            .padding()
        }
        .frame(width: 460)
        .frame(minHeight: 420)
    }

    private var hotkeyBinding: Binding<String> {
        Binding(
            get: { draft.scene.hotkey ?? "" },
            set: { draft.scene.hotkey = SceneEditorDraft.normalizedHotkey($0) })
    }

    private func addSourceLayer(_ source: CaptureSourceDescriptor) {
        draft.scene.layers.append(SceneLayer(
            sourceRef: .captureSource(source.id),
            zIndex: nextZIndex()))
    }

    private func addColourLayer() {
        draft.scene.layers.append(SceneLayer(
            sourceRef: .colour(hex: "#000000"),
            zIndex: nextZIndex()))
    }

    private func removeLayer(id: UUID) {
        draft.scene.layers.removeAll { $0.id == id }
    }

    private func nextZIndex() -> Int {
        (draft.scene.layers.map(\.zIndex).max() ?? -1) + 1
    }
}

private struct SceneLayerEditorRow: View {
    @Binding var layer: SceneLayer

    let sources: [CaptureSourceDescriptor]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $layer.visible) {
                    Text(layerTitle)
                        .lineLimit(1)
                }
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove layer")
                .accessibilityLabel("Remove layer")
            }

            HStack {
                Stepper(value: $layer.zIndex, in: -32...32) {
                    Text("Order \(layer.zIndex)")
                        .font(.caption)
                }
                Spacer()
                Text("\(Int(layer.opacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: opacityBinding, in: 0...1) {
                Text("Opacity")
            }
        }
        .padding(.vertical, 4)
    }

    private var layerTitle: String {
        switch layer.sourceRef {
        case .captureSource(let id):
            sources.first(where: { $0.id == id })?.displayName ?? "Capture Source"
        case .still:
            "Still"
        case .colour(let hex):
            "Colour \(hex)"
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { Double(layer.opacity) },
            set: { layer.opacity = Float($0) })
    }
}

// MARK: - Program panel state

/// Observable state for the Program Panel. Bridges between the UI and
/// the `ProgramSession` actor.
@Observable
@MainActor
final class ProgramPanelState {
    var isRunning = false
    var currentSceneId: UUID?
    var activeVideoSourceCount = 0
    var budgetMax = 4
    var isBudgetExhausted = false
    var capabilitySufficient = true
    var statusMessage = ""
    var isRefreshingSources = false
    var isStarting = false
    var isStopping = false

    var sources: [CaptureSourceDescriptor] {
        sourceBindings.map(\.descriptor)
    }

    private var session: ProgramSession?
    private var sourceBindings: [ProgramCaptureSource] = []

    func refreshCapability() {
        let verdict = Capabilities.current.tier(for: .programMode)
        capabilitySufficient = verdict.tier >= .accelerated
        if !capabilitySufficient {
            statusMessage = "Hardware insufficient: \(verdict.reason)"
        }
        Task {
            let budget = EncoderBudget()
            budgetMax = await budget.maxConcurrent
            updateBudgetReadout()
        }
    }

    func refreshSources() async {
        guard !isRefreshingSources else { return }
        isRefreshingSources = true
        defer { isRefreshingSources = false }

        var refreshed: [ProgramCaptureSource] = []
        do {
            let screenOptions = try await CaptureSourceCatalog.screenOptions()
            refreshed.append(contentsOf: screenOptions.map(Self.descriptor(for:)))
        } catch {
            statusMessage = "Could not refresh screen sources: \(error.localizedDescription)"
        }

        refreshed.append(contentsOf: CaptureSourceCatalog.webcamOptions().map(Self.webcamDescriptor(for:)))
        refreshed.append(contentsOf: CaptureSourceCatalog.microphoneOptions().map(Self.microphoneDescriptor(for:)))
        sourceBindings = refreshed
        updateBudgetReadout()
        if sources.isEmpty, statusMessage.isEmpty {
            statusMessage = "No capture sources found."
        } else if !sources.isEmpty {
            statusMessage = "Found \(sources.count) capture source\(sources.count == 1 ? "" : "s")."
        }
    }

    func switchScene(to sceneId: UUID) {
        currentSceneId = sceneId
        Task {
            await session?.switchScene(to: sceneId)
        }
    }

    func start(model: EditorModel, scenes: [SceneDefinition]) {
        guard !isRunning, !isStarting, !sourceBindings.isEmpty, let first = scenes.first else { return }
        guard let root = model.resolvedRecordingsFolder(promptIfMissing: true) else {
            statusMessage = "Choose a recordings folder before starting Program Mode."
            return
        }
        let programSession = ProgramSession(budget: EncoderBudget(), rootURL: root)
        let captureSources = sourceBindings
        let initialScenes = scenes
        let renderSize = model.project.renderSize
        session = programSession
        isStarting = true
        currentSceneId = first.id
        statusMessage = "Starting Program Mode..."
        Task {
            defer { isStarting = false }
            do {
                try await programSession.start(
                    captureSources: captureSources,
                    scenes: initialScenes,
                    renderSize: renderSize)
                isRunning = true
                statusMessage = "Program session recording."
            } catch {
                session = nil
                isRunning = false
                currentSceneId = nil
                statusMessage = error.localizedDescription
            }
        }
    }

    func stop(model: EditorModel) {
        guard isRunning, !isStopping, let session else { return }
        isStopping = true
        isRunning = false
        statusMessage = "Stopping Program Mode..."
        Task {
            defer {
                isStopping = false
                self.session = nil
                currentSceneId = nil
            }
            do {
                let result = try await session.stop()
                ProgramLanding.land(result: result, model: model)
                statusMessage = "Program session landed."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Tears down the session if the panel disappears while recording.
    /// Best-effort: errors are logged, not surfaced (panel is gone).
    func teardownIfRunning() {
        guard isRunning, let session else { return }
        isRunning = false
        Task {
            do {
                _ = try await session.stop()
            } catch {
                NSLog("[ProgramPanelState] teardown stop failed: \(error)")
            }
            self.session = nil
            currentSceneId = nil
        }
    }

    private func updateBudgetReadout() {
        activeVideoSourceCount = sources.filter(\.kind.isVideo).count
        isBudgetExhausted = activeVideoSourceCount > budgetMax
    }

    private static func descriptor(for option: CaptureSourceOption) -> ProgramCaptureSource {
        let size = option.target.outputSize
        let descriptor = CaptureSourceDescriptor(
            id: stableUUID(for: "screen:\(option.id)"),
            kind: option.target.sourceKind,
            displayName: option.title,
            relativePath: "\(filenameStem(from: option.id)).mov",
            width: size.width,
            height: size.height,
            frameRate: 30)
        return ProgramCaptureSource(descriptor: descriptor, endpoint: .screen(option.target))
    }

    private static func webcamDescriptor(for option: CaptureDeviceOption) -> ProgramCaptureSource {
        let descriptor = CaptureSourceDescriptor(
            id: stableUUID(for: "webcam:\(option.id)"),
            kind: .webcam,
            displayName: option.title,
            relativePath: "\(filenameStem(from: "webcam-\(option.id)")).mov",
            width: 1920,
            height: 1080,
            frameRate: 30)
        return ProgramCaptureSource(descriptor: descriptor, endpoint: .webcam(deviceID: option.id))
    }

    private static func microphoneDescriptor(for option: CaptureDeviceOption) -> ProgramCaptureSource {
        let descriptor = CaptureSourceDescriptor(
            id: stableUUID(for: "microphone:\(option.id)"),
            kind: .microphone,
            displayName: option.title,
            relativePath: "\(filenameStem(from: "microphone-\(option.id)")).mov",
            sampleRate: 48_000,
            channels: 1)
        return ProgramCaptureSource(descriptor: descriptor, endpoint: .microphone(deviceID: option.id))
    }

    private static func filenameStem(from value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let stem = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return stem.isEmpty ? "source" : stem
    }

    private static func stableUUID(for value: String) -> UUID {
        let bytes = Array(value.utf8)
        let first = fnv1a64(bytes: bytes, seed: 0xcbf2_9ce4_8422_2325)
        let second = fnv1a64(bytes: bytes.reversed(), seed: 0x8422_2325_cbf2_9ce4)
        var uuidBytes: [UInt8] = []
        uuidBytes.reserveCapacity(16)
        for shift in stride(from: 56, through: 0, by: -8) {
            uuidBytes.append(UInt8((first >> UInt64(shift)) & 0xff))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            uuidBytes.append(UInt8((second >> UInt64(shift)) & 0xff))
        }
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
    }

    private static func fnv1a64<S: Sequence>(bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - Editor intents

extension EditorModel {
    func addProgramScene(_ scene: SceneDefinition) {
        performUndoable("Add Program Scene") {
            var doc = project.sceneDoc
            doc.scenes.append(scene)
            project.sceneDoc = migrateSceneDoc(doc)
            statusMessage = "Added program scene \(scene.name)."
        }
    }

    func updateProgramScene(_ scene: SceneDefinition) {
        performUndoable("Edit Program Scene") {
            var doc = project.sceneDoc
            guard let index = doc.scenes.firstIndex(where: { $0.id == scene.id }) else { return }
            doc.scenes[index] = scene
            project.sceneDoc = migrateSceneDoc(doc)
            statusMessage = "Updated program scene \(scene.name)."
        }
    }

    func deleteProgramScene(id: UUID) {
        performUndoable("Delete Program Scene") {
            var doc = project.sceneDoc
            guard let scene = doc.scenes.first(where: { $0.id == id }) else { return }
            doc.scenes.removeAll { $0.id == id }
            project.sceneDoc = migrateSceneDoc(doc)
            statusMessage = "Deleted program scene \(scene.name)."
        }
    }
}
