import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct LocalCutStudioApp: App {
    var body: some Scene {
        WindowGroup {
            EditorView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

/// Top-level editor layout: media bin · preview · inspector across the top, with
/// the timeline spanning the bottom. This is the native shell that mirrors the
/// browser editor's three-pane workspace.
struct EditorView: View {
    @State private var model = EditorModel()

    var body: some View {
        VSplitView {
            HSplitView {
                MediaBinView(model: model)
                    .frame(minWidth: 200, idealWidth: 240)

                PreviewView(model: model)
                    .frame(minWidth: 380)
                    .layoutPriority(1)

                InspectorView(model: model)
                    .frame(minWidth: 240, idealWidth: 280)
            }
            .frame(minHeight: 320)

            TimelineView(model: model)
                .frame(minHeight: 200, idealHeight: 260)
        }
        .toolbar { toolbarContent }
        .navigationTitle(model.project.name)
        .overlay(alignment: .bottom) { statusBar }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.splitSelectedClipAtPlayhead()
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .disabled(model.selectedClipID == nil)
            .help("Split clip at playhead")

            Button(role: .destructive) {
                model.deleteSelectedClip()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selectedClipID == nil)
            .keyboardShortcut(.delete, modifiers: [])
            .help("Delete selected clip")

            Spacer()

            if model.isExporting, let progress = model.exportProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
            }

            Button {
                exportTapped()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.isExporting || model.totalDuration <= 0)
            .help("Export movie…")
        }
    }

    private var statusBar: some View {
        Text(model.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 6)
            .allowsHitTesting(false)
    }

    private func exportTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(model.project.name).mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(to: url) }
    }
}
