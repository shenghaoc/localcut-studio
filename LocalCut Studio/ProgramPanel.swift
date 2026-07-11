import SwiftUI
import LocalCutCore

// MARK: - Program panel

/// The Program Mode panel: sources, scenes, hotkeys, start/stop, budget
/// readout, and program monitor (sharing existing preview output).
struct ProgramPanel: View {
    @Bindable var model: EditorModel

    @State private var programState = ProgramPanelState()
    @State private var editingSceneDraft: SceneEditorDraft?
    @FocusState private var receivesProgramHotkeys: Bool

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
            && model.programSession == nil
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
        .focusable()
        .focused($receivesProgramHotkeys)
        .onAppear {
            programState.refreshCapability(budget: model.encoderBudget)
            programState.syncSessionState(model: model, scenes: scenes)
            receivesProgramHotkeys = true
        }
        .onDisappear {
            programState.teardownIfRunning(budget: model.encoderBudget, model: model)
        }
        .onChange(of: programState.isRunning) { _, isRunning in
            if isRunning {
                receivesProgramHotkeys = true
            }
        }
        .onChange(of: model.programSession != nil) { _, _ in
            programState.syncSessionState(model: model, scenes: scenes)
        }
        .onKeyPress { press in
            guard programState.isRunning,
                  let char = press.characters.first.map(String.init),
                  let scene = scenes.first(where: { $0.hotkey == char }) else {
                return .ignored
            }
            programState.switchScene(to: scene.id, model: model)
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
                Button { [weak programState] in
                    Task { await programState?.refreshSources() }
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
                ForEach(Array(programState.sourceBindings.enumerated()), id: \.element.id) { index, binding in
                    HStack {
                        Toggle("", isOn: sourceToggleBinding(index: index))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .disabled(programState.isRunning)
                            .accessibilityLabel("Enable \(binding.descriptor.displayName)")
                        Image(systemName: sourceIcon(for: binding.descriptor.kind))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(binding.descriptor.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .opacity(binding.isEnabled ? 1.0 : 0.5)
                        Spacer()
                        if binding.descriptor.kind.isVideo {
                            Text("\(binding.descriptor.width ?? 0)x\(binding.descriptor.height ?? 0)")
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
                programState.switchScene(to: scene.id, model: model)
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

    private func sourceToggleBinding(index: Int) -> Binding<Bool> {
        Binding(
            get: { programState.sourceBindings[index].isEnabled },
            set: { newValue in
                programState.sourceBindings[index].isEnabled = newValue
                programState.updateBudgetReadout()
            })
    }

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
