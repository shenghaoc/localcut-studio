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
            get: { RailGroup.resolve(groupID) },
            set: { groupID = $0.rawValue })
    }

    private var tool: Binding<ToolPanel> {
        Binding(
            get: { ToolPanel.resolve(toolID) },
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
                .accessibilityLabel("\(group.wrappedValue.title) panel")
                // Report the active pane title — a bare "Selected" is implicit
                // in any segmented control and carries no extra information.
                // Mirrors the secondary picker below.
                .accessibilityValue(group.wrappedValue.title)
                // The segmented switcher stands in for a per-pane EditorPanelHeader:
                // marking it a header keeps the rail reachable from the VoiceOver
                // rotor's Headings list, announcing the active pane, without a
                // redundant title under tabs that already name the panel.
                .accessibilityAddTraits(.isHeader)
                .help("Switch between Inspector, Audio, Captions, and Tools panels")

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
            .accessibilityAddTraits(.isHeader)
            .help("Switch between Beats, Renders, Markers, Program, and Publish tools")

            Divider()

            switch tool.wrappedValue {
            case .beats:
                toolForm { BeatToolsInspectorView(model: model) }
            case .renders:
                toolForm { RenderQueueInspectorView(model: model) }
            case .markers:
                toolForm { MarkersInspectorView(model: model) }
            case .program:
                ProgramPanel(model: model)
            case .publish:
                PublishPanel(model: model)
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
/// `internal` (not `private`) so the stale-value fallback in `resolve` can be
/// unit-tested.
enum RailGroup: String, CaseIterable, Identifiable, Sendable {
    case inspector
    case audio
    case captions
    case tools

    var id: String { rawValue }

    /// Maps a persisted `@SceneStorage` raw value to a group, falling back to
    /// `.inspector` when the stored string is unknown (e.g. a key written by an
    /// older layout). Keeps a corrupt/stale scene value from dropping the rail.
    static func resolve(_ rawValue: String) -> RailGroup {
        RailGroup(rawValue: rawValue) ?? .inspector
    }

    var title: String {
        switch self {
        case .inspector: String(localized: "Inspector")
        case .audio: String(localized: "Audio")
        case .captions: String(localized: "Captions")
        case .tools: String(localized: "Tools")
        }
    }
}

/// Secondary panels grouped under the Tools tab.
enum ToolPanel: String, CaseIterable, Identifiable, Sendable {
    case beats
    case renders
    case markers
    case program
    case publish

    var id: String { rawValue }

    /// Falls back to `.beats` for an unknown stored value (see `RailGroup.resolve`).
    static func resolve(_ rawValue: String) -> ToolPanel {
        ToolPanel(rawValue: rawValue) ?? .beats
    }

    var title: String {
        switch self {
        case .beats: String(localized: "Beats")
        case .renders: String(localized: "Renders")
        case .markers: String(localized: "Markers")
        case .program: String(localized: "Program")
        case .publish: String(localized: "Publish")
        }
    }
}
