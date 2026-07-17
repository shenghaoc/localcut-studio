import SwiftUI
import LocalCutCore

// MARK: - Scene editor draft

struct SceneEditorDraft: Identifiable, Sendable {
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

// MARK: - Scene editor sheet

struct SceneEditorSheet: View {
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
        .frame(minWidth: 460)
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

// MARK: - Scene layer editor row

struct SceneLayerEditorRow: View {
    @Binding var layer: SceneLayer

    let sources: [CaptureSourceDescriptor]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $layer.visible) {
                    Text(layerTitle)
                        .lineLimit(1)
                        .help(layerTitle)
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
