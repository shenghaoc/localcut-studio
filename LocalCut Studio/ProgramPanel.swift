import SwiftUI
import LocalCutCore

// MARK: - Program panel

/// The Program Mode panel: sources, scenes, hotkeys, start/stop, budget
/// readout, and program monitor (sharing existing preview output).
struct ProgramPanel: View {
    @Bindable var model: EditorModel

    @State private var programState = ProgramPanelState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header.
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

            Divider()

            // Budget readout.
            budgetReadout

            Divider()

            // Sources section.
            sourcesSection

            Divider()

            // Scenes section.
            scenesSection

            Divider()

            // Start/Stop controls.
            controlsSection
        }
        .padding()
        .frame(minWidth: 280)
        .onAppear {
            programState.refreshCapability()
        }
    }

    // MARK: - Budget readout

    private var budgetReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Encoder Budget")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack {
                Text("\(programState.activeSourceCount) / \(programState.budgetMax) sources active")
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if programState.sources.isEmpty {
                Text("No capture sources available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(programState.sources, id: \.id) { source in
                    HStack {
                        Image(systemName: sourceIcon(for: source.kind))
                            .frame(width: 16)
                        Text(source.displayName)
                            .font(.caption)
                        Spacer()
                        if source.kind.isVideo {
                            Text("\(source.width ?? 0)×\(source.height ?? 0)")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Scenes")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    programState.addScene()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(programState.isRunning)
            }

            if programState.scenes.isEmpty {
                Text("No scenes defined")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(programState.scenes) { scene in
                    sceneRow(scene)
                }
            }

            // Hotkey conflict warning.
            if !programState.hotkeyConflicts.isEmpty {
                Label("Hotkey conflict: \(programState.hotkeyConflicts.joined(separator: ", "))",
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
            Text(scene.name)
                .font(.caption)
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
                programState.editScene(scene)
            } label: {
                Image(systemName: "pencil")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(programState.isRunning)
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
        HStack {
            if programState.isRunning {
                Button {
                    programState.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    programState.start()
                } label: {
                    Label("Start Program", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!programState.canStart)
            }
        }
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

// MARK: - Program panel state

/// Observable state for the Program Panel. Bridges between the UI and
/// the `ProgramSession` actor.
@Observable
@MainActor
final class ProgramPanelState {
    var isRunning = false
    var sources: [CaptureSourceDescriptor] = []
    var scenes: [SceneDefinition] = []
    var currentSceneId: UUID?
    var hotkeyConflicts: [String] = []
    var activeSourceCount = 0
    var budgetMax = 4
    var isBudgetExhausted = false
    var capabilitySufficient = true
    var statusMessage = ""

    private var session: ProgramSession?
    private var budget: EncoderBudget?

    func refreshCapability() {
        let verdict = Capabilities.current.tier(for: .programMode)
        capabilitySufficient = verdict.tier >= .accelerated
        if !capabilitySufficient {
            statusMessage = "Hardware insufficient: \(verdict.reason)"
        }
    }

    func addScene() {
        let scene = SceneDefinition(name: "Scene \(scenes.count + 1)", layers: [])
        scenes.append(scene)
        hotkeyConflicts = detectHotkeyConflicts(in: scenes)
    }

    func editScene(_ scene: SceneDefinition) {
        // Scene editing is handled by the scene editor sheet.
        // For now, this is a placeholder.
    }

    func switchScene(to sceneId: UUID) {
        currentSceneId = sceneId
        Task {
            await session?.switchScene(to: sceneId)
        }
    }

    var canStart: Bool {
        !isRunning
            && !sources.isEmpty
            && !scenes.isEmpty
            && hotkeyConflicts.isEmpty
            && capabilitySufficient
            && !isBudgetExhausted
    }

    func start() {
        guard canStart else { return }
        // Start is delegated to the EditorModel which owns the session.
        // This is a placeholder — the actual start path wires through
        // EditorModel.startProgramMode().
        isRunning = true
        if let first = scenes.first {
            currentSceneId = first.id
        }
    }

    func stop() {
        guard isRunning else { return }
        // Stop is delegated to the EditorModel.
        isRunning = false
        currentSceneId = nil
    }
}
