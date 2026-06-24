import SwiftUI
import AVFoundation
import LocalCutCore

/// Inspector section listing every marker. Click the timecode to seek, edit
/// the name in place (coalesced into one undo step), or delete the row.
struct MarkersInspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Markers") {
            HStack {
                Button("Add at Playhead") { model.addMarkerAtPlayhead() }
                Spacer()
            }

            if model.project.markers.isEmpty {
                Text("No markers. Press M while the timeline is focused, or use the button above.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach(model.project.markers) { marker in
                markerRow(marker)
            }
        }
    }

    @ViewBuilder
    private func markerRow(_ marker: TimelineMarker) -> some View {
        HStack(spacing: 6) {
            Button {
                model.seekToMarker(id: marker.id)
            } label: {
                Text(TimeFormatting.timecode(marker.time.seconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Seek to marker")
            .accessibilityLabel("Seek to \(TimeFormatting.timecode(marker.time.seconds))")

            TextField("Name", text: Binding(
                get: { marker.name },
                set: { newName in model.updateMarkerCoalesced(id: marker.id, name: newName) }))

            Button(role: .destructive) {
                model.removeMarker(id: marker.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove marker")
            .accessibilityLabel("Remove marker")
        }
        .padding(.vertical, 2)
        .background(
            // Subtle row highlight when this marker is the timeline selection.
            (model.selectedMarkerID == marker.id ? Color.accentColor.opacity(0.08) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4)))
        .contentShape(Rectangle())
        // Funnel through `selectMarker(id:)` so the row tap honours the same
        // mutual-exclusivity contract as every other marker-selection path
        // (review feedback on the original revision: a bare assignment here
        // would leave clip / transition / media selection stale).
        .onTapGesture { model.selectMarker(id: marker.id) }
    }
}
