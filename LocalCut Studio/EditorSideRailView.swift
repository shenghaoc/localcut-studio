import SwiftUI

/// Native counterpart to browser-editor's side rail. A primary segmented
/// control keeps Inspector, Audio, Captions, and Tools visible, while heavier
/// project tools stay grouped behind a secondary segmented control.
struct EditorSideRailView: View {
    @Bindable var model: EditorModel
    let onCollapse: () -> Void

    // Fresh storage keys (the old "editor.sideRailPanel" flat key is abandoned
    // so any stale persisted value falls back to the Inspector group rather than
    // restoring a panel that no longer exists in this layout).
    @SceneStorage("editor.railGroup") private var groupID = RailGroup.inspector.rawValue
    @SceneStorage("editor.railTool") private var toolID = ToolPanel.beats.rawValue

    private var group: Binding<RailGroup> {
        Binding(
            get: { RailGroup(rawValue: groupID) ?? .inspector },
            set: { groupID = $0.rawValue })
    }

    private var tool: Binding<ToolPanel> {
        Binding(
            get: { ToolPanel(rawValue: toolID) ?? .beats },
            set: { toolID = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: group) {
                    ForEach(RailGroup.allCases) { group in
                        Text(group.title).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Side panel")
                .accessibilityValue(group.wrappedValue.title)
                // The segmented switcher stands in for a per-pane EditorPanelHeader:
                // marking it a header keeps the rail reachable from the VoiceOver
                // rotor's Headings list, announcing the active pane, without a
                // redundant title under tabs that already name the panel.
                .accessibilityAddTraits(.isHeader)

                Button {
                    onCollapse()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Hide inspector panel")
                .accessibilityLabel("Hide inspector panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            groupContent
        }
    }

    @ViewBuilder
    private var groupContent: some View {
        switch group.wrappedValue {
        case .inspector:
            InspectorView(model: model)
        case .audio:
            toolForm { AudioInspectorView(model: model) }
        case .captions:
            toolForm { CaptionsInspectorView(model: model) }
        case .tools:
            toolsGroup
        }
    }

    /// The Tools group nests a second segmented control so Beats/Renders/Markers
    /// stay grouped under one primary tab instead of bloating the top strip.
    private var toolsGroup: some View {
        VStack(spacing: 0) {
            Picker("", selection: tool) {
                ForEach(ToolPanel.allCases) { tool in
                    Text(tool.title).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("Project tool")
            .accessibilityValue(tool.wrappedValue.title)

            Divider()

            switch tool.wrappedValue {
            case .beats:
                toolForm { BeatToolsInspectorView(model: model) }
            case .renders:
                toolForm { RenderQueueInspectorView(model: model) }
            case .markers:
                toolForm { MarkersInspectorView(model: model) }
            }
        }
    }

    private func toolForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
    }
}

/// Primary side-rail groups, mirroring browser-editor's top-level rail tabs.
private enum RailGroup: String, CaseIterable, Identifiable {
    case inspector
    case audio
    case captions
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspector: "Inspector"
        case .audio: "Audio"
        case .captions: "Captions"
        case .tools: "Tools"
        }
    }
}

/// Secondary panels grouped under the Tools tab.
private enum ToolPanel: String, CaseIterable, Identifiable {
    case beats
    case renders
    case markers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beats: "Beats"
        case .renders: "Renders"
        case .markers: "Markers"
        }
    }
}
