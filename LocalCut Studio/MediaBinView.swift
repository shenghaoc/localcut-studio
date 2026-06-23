import SwiftUI
import UniformTypeIdentifiers

/// The media library: imported source files with poster frames. Selecting an
/// item shows it in the inspector; the add button (or double-click) appends it
/// to the timeline.
struct MediaBinView: View {
    @Bindable var model: EditorModel
    @State private var showImporter = false
    @State private var copyImportsIntoBundle = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Text("Media")
                        .font(.headline)
                    Spacer()
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Import media…")
                    .accessibilityLabel("Import media")
                }

                Toggle("Copy into Bundle", isOn: $copyImportsIntoBundle)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Copy newly imported media into .lcbundle saves")
                    .accessibilityLabel("Copy imported media into bundle")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if model.project.mediaItems.isEmpty {
                ContentUnavailableView(
                    "No Media",
                    systemImage: "tray",
                    description: Text("Import video or audio to start editing."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.project.mediaItems) { item in
                            MediaRow(item: item, isSelected: model.selectedMediaID == item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedMediaID = item.id }
                                .onTapGesture(count: 2) { model.addToTimeline(mediaID: item.id) }
                                .contextMenu {
                                    Button("Add to Timeline") { model.addToTimeline(mediaID: item.id) }
                                    Divider()
                                    Button("Remove from Project", role: .destructive) { model.removeMedia(itemID: item.id) }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(item.name), \(TimeFormatting.timecode(item.durationSeconds))")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAddTraits(model.selectedMediaID == item.id ? .isSelected : [])
                                .accessibilityAction(named: "Add to Timeline") { model.addToTimeline(mediaID: item.id) }
                                .accessibilityAction(named: "Remove from Project") { model.removeMedia(itemID: item.id) }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.movie, .video, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let wantsBundling = copyImportsIntoBundle
                Task { await model.importMedia(urls: urls, wantsBundling: wantsBundling) }
            }
        }
    }
}

private struct MediaRow: View {
    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                if let thumb = item.thumbnail {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: item.hasVideo ? "film" : "waveform")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .font(.subheadline)
                Text(TimeFormatting.timecode(item.durationSeconds))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(isSelected ? Color(.selectedContentBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }
}
