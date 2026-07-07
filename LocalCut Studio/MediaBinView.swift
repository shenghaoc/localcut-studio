import SwiftUI
import UniformTypeIdentifiers
import CoreMedia
import LocalCutCore

/// The media library: imported source files with poster frames. Selecting an
/// item shows it in the inspector; the add button (or double-click) appends it
/// to the timeline.
struct MediaBinView: View {
    @Bindable var model: EditorModel
    @State private var showImporter = false
    @FocusState private var focusedMediaID: MediaItem.ID?

    var body: some View {
        VStack(spacing: 0) {
            EditorPanelHeader("Media") {
                Text("\(model.project.mediaItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(model.project.mediaItems.count) imported media items")

                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Import media…")
                .accessibilityLabel("Import media")
            }

            Divider()

            Group {
                if model.project.mediaItems.isEmpty && model.recoveredCaptureSessions.isEmpty {
                    ContentUnavailableView {
                        Label("No media yet", systemImage: "film.stack")
                    } description: {
                        Text("Import video or audio to start editing.")
                    } actions: {
                        Button("Import Media") {
                            showImporter = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            if !model.recoveredCaptureSessions.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Recovered")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 4)
                                    ForEach(model.recoveredCaptureSessions) { session in
                                        RecoveredRecordingRow(session: session) {
                                            model.importRecoveredCaptureSession(session)
                                        }
                                    }
                                }
                                .padding(.bottom, 6)
                            }

                            ForEach(model.project.mediaItems) { item in
                                MediaRow(item: item,
                                         isSelected: model.selectedMediaID == item.id,
                                         isFocused: focusedMediaID == item.id,
                                         onSelect: {
                                             selectMedia(item.id)
                                         },
                                         onAdd: { model.addToTimeline(mediaID: item.id) },
                                         onRemove: { model.removeMedia(itemID: item.id) })
                                    .focusable()
                                    .focused($focusedMediaID, equals: item.id)
                                    .contextMenu {
                                        Button("Add to Timeline") { model.addToTimeline(mediaID: item.id) }
                                        Divider()
                                        Button("Remove from Project", role: .destructive) { model.removeMedia(itemID: item.id) }
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .onMoveCommand(perform: moveMediaSelection)
                    .onDeleteCommand(perform: deleteFocusedMedia)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Import behaviour lives quietly at the foot of the panel rather than
            // above the library — it's a save-time preference, not a primary action.
            Toggle("Copy imports into bundle", isOn: $model.copyImportsIntoBundle)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Copy newly imported media into .lcbundle saves")
                .accessibilityLabel("Copy imported media into bundle")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.movie, .video, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let wantsBundling = model.copyImportsIntoBundle
                Task { [weak model] in await model?.importMedia(urls: urls, wantsBundling: wantsBundling) }
            }
        }
        .onChange(of: model.selectedMediaID) { _, newValue in
            focusedMediaID = newValue
        }
        .onChange(of: model.project.mediaItems.map(\.id)) { _, ids in
            if let focusedMediaID, !ids.contains(focusedMediaID) {
                self.focusedMediaID = ids.first
            }
        }
    }

    private func selectMedia(_ id: MediaItem.ID) {
        model.selectMedia(id: id)
        focusedMediaID = id
    }

    private func moveMediaSelection(_ direction: MoveCommandDirection) {
        let items = model.project.mediaItems
        guard !items.isEmpty else { return }
        let currentID = focusedMediaID ?? model.selectedMediaID
        let currentIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } }

        let targetIndex: Int? = switch direction {
        case .up:
            currentIndex.map { max(0, $0 - 1) } ?? items.count - 1
        case .down:
            currentIndex.map { min(items.count - 1, $0 + 1) } ?? 0
        default:
            nil
        }

        guard let targetIndex else { return }
        selectMedia(items[targetIndex].id)
    }

    private func deleteFocusedMedia() {
        guard let id = focusedMediaID ?? model.selectedMediaID else { return }
        model.removeMedia(itemID: id)
    }
}

private struct RecoveredRecordingRow: View {
    let session: CaptureSessionResult
    let importAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "recordingtape")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recovered recording")
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Add") { importAction() }
                .controlSize(.small)
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recovered recording, \(detail)")
        .accessibilityAction(named: "Add to Timeline") { importAction() }
    }

    private var detail: String {
        let sources = session.manifest.recoveredSources
        let duration = sources.map { $0.duration.seconds }.max() ?? 0
        let sourceLabel = sources.count == 1 ? "1 source" : "\(sources.count) sources"
        return "\(sourceLabel), \(TimeFormatting.timecode(duration))"
    }
}

private struct MediaRow: View {
    let item: MediaItem
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            mediaSummary

            HStack(spacing: 4) {
                Button {
                    onAdd()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Add \(item.name) to timeline")
                .accessibilityLabel("Add \(item.name) to timeline")

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Remove \(item.name) from project")
                .accessibilityLabel("Remove \(item.name) from project")
            }
        }
        .padding(6)
        .background(isSelected ? Color(.selectedContentBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.lcAccent : Color.clear, lineWidth: 2))
    }

    private var mediaSummary: some View {
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
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onAdd() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(TimeFormatting.timecode(item.durationSeconds))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Select") { onSelect() }
        .accessibilityAction(named: "Add to Timeline") { onAdd() }
        .accessibilityAction(named: "Remove from Project") { onRemove() }
    }
}
