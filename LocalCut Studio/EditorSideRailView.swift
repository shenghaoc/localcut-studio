import SwiftUI

/// Native counterpart to browser-editor's side rail. Mirrors its **grouped,
/// always-visible tab strip** instead of hiding panels behind a dropdown: a
/// primary segmented control switches between Inspector · Audio · Text · Tools,
/// and the heavier project tools (Beats/Renders/Markers) sit behind a secondary
/// segmented control under the Tools group. This keeps every panel one visible
/// click away — the dropdown crammed six flat panels behind a menu that gave no
/// hint of what was inside.
struct EditorSideRailView: View {
    @Bindable var model: EditorModel

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
            Picker("Side panel", selection: group) {
                ForEach(RailGroup.allCases) { group in
                    Text(group.title).tag(group)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("Side panel")

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
        case .text:
            toolForm { CaptionsInspectorView(model: model) }
        case .tools:
            toolsGroup
        }
    }

    /// The Tools group nests a second segmented control so Beats/Renders/Markers
    /// stay grouped under one primary tab instead of bloating the top strip.
    private var toolsGroup: some View {
        VStack(spacing: 0) {
            Picker("Project tool", selection: tool) {
                ForEach(ToolPanel.allCases) { tool in
                    Text(tool.title).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("Project tool")

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
    case text
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspector: "Inspector"
        case .audio: "Audio"
        case .text: "Text"
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
