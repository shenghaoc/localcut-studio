import SwiftUI

/// Native counterpart to browser-editor's side rail: one focused panel at a
/// time, with contextual inspection separated from heavier editing tools.
struct EditorSideRailView: View {
    @Bindable var model: EditorModel
    @SceneStorage("editor.sideRailPanel") private var selectedPanelID = EditorSidePanel.inspector.rawValue

    private var selectedPanel: Binding<EditorSidePanel> {
        Binding(
            get: { EditorSidePanel(rawValue: selectedPanelID) ?? .inspector },
            set: { selectedPanelID = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorPanelHeader(selectedPanel.wrappedValue.title) {
                Picker("Side panel", selection: selectedPanel) {
                    ForEach(EditorSidePanel.allCases) { panel in
                        Label(panel.title, systemImage: panel.systemImage)
                            .tag(panel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 142)
                .help("Switch side panel")
                .accessibilityLabel("Side panel")
            }

            Divider()

            panelContent
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedPanel.wrappedValue {
        case .inspector:
            InspectorView(model: model)
        case .audio:
            toolForm { AudioInspectorView(model: model) }
        case .beats:
            toolForm { BeatToolsInspectorView(model: model) }
        case .captions:
            toolForm { CaptionsInspectorView(model: model) }
        case .renders:
            toolForm { RenderQueueInspectorView(model: model) }
        case .markers:
            toolForm { MarkersInspectorView(model: model) }
        }
    }

    private func toolForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
    }
}

private enum EditorSidePanel: String, CaseIterable, Identifiable {
    case inspector
    case audio
    case beats
    case captions
    case renders
    case markers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspector: "Inspector"
        case .audio: "Audio"
        case .beats: "Beats"
        case .captions: "Captions"
        case .renders: "Renders"
        case .markers: "Markers"
        }
    }

    var systemImage: String {
        switch self {
        case .inspector: "slider.horizontal.3"
        case .audio: "speaker.wave.2"
        case .beats: "waveform.path.ecg"
        case .captions: "captions.bubble"
        case .renders: "film.stack"
        case .markers: "mappin"
        }
    }
}
