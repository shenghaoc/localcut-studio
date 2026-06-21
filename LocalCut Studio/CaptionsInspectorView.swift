import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

/// Inspector section listing every caption track + line. Per-line editing,
/// import, default-style preset picking, and `.lccaption` import/export all live
/// here so the main `InspectorView` stays a thin router.
struct CaptionsInspectorView: View {
    @Bindable var model: EditorModel

    @State private var showSRTImporter = false
    @State private var showPresetImporter = false
    @State private var pickerTrackID: CaptionTrack.ID?

    var body: some View {
        Section("Captions") {
            HStack {
                Button("Import SRT/VTT…") { showSRTImporter = true }
                Button("Add Empty Track") { model.addEmptyCaptionTrack() }
                Spacer()
            }

            if model.project.captionTracks.isEmpty {
                Text("No caption tracks. Import an SRT/VTT or add an empty track to begin.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach(model.project.captionTracks) { track in
                trackBlock(track)
            }
        }
        .fileImporter(
            isPresented: $showSRTImporter,
            allowedContentTypes: captionContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importCaptionTrack(from: url) }
            }
        }
        .fileImporter(
            isPresented: $showPresetImporter,
            allowedContentTypes: presetContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first, let trackID = pickerTrackID {
                importPreset(from: url, into: trackID)
            }
            pickerTrackID = nil
        }
    }

    @ViewBuilder
    private func trackBlock(_ track: CaptionTrack) -> some View {
        DisclosureGroup {
            Toggle("Muted", isOn: Binding(
                get: { track.isMuted },
                set: { new in
                    track.isMuted = new
                    model.markDirty()
                    model.scheduleRebuild()
                }))

            Picker("Preset", selection: presetSelectionBinding(for: track)) {
                Text("Custom").tag(Optional<String>.none)
                ForEach(BuiltInCaptionPresets.all, id: \.name) { preset in
                    Text(preset.name).tag(Optional(preset.name))
                }
            }

            HStack {
                Button("Import Preset…") {
                    pickerTrackID = track.id
                    showPresetImporter = true
                }
                Button("Export Preset…") { exportPreset(for: track) }
                Spacer()
                Button(role: .destructive) {
                    model.removeCaptionTrack(id: track.id)
                } label: { Image(systemName: "trash") }
                    .help("Remove track")
            }

            ForEach(track.lines) { line in
                lineRow(line, in: track)
            }

            HStack {
                Button("Add Line at Playhead") { model.addCaptionLine(in: track.id) }
                Spacer()
            }
        } label: {
            HStack {
                Text(track.name).bold()
                Spacer()
                Text("\(track.lines.count) line(s)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func lineRow(_ line: CaptionLine, in track: CaptionTrack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(TimeFormatting.timecode(line.range.start.seconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("→")
                    .foregroundStyle(.secondary)
                Text(TimeFormatting.timecode(line.range.end.seconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    model.removeCaptionLine(line.id, in: track.id)
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            TextField("Caption text", text: Binding(
                get: { line.text },
                set: { newText in
                    var updated = line
                    updated.text = newText
                    model.updateCaptionLine(updated, in: track.id)
                }), axis: .vertical)
                .lineLimit(1...3)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Preset binding

    /// Drives the per-track preset picker. Setting a value applies the matching
    /// built-in preset's style; `nil` keeps the current style (no-op).
    private func presetSelectionBinding(for track: CaptionTrack) -> Binding<String?> {
        Binding(
            get: { matchedPresetName(for: track.defaultStyle) },
            set: { name in
                guard let name,
                      let preset = BuiltInCaptionPresets.all.first(where: { $0.name == name }) else { return }
                model.updateCaptionTrackDefaultStyle(preset.style, in: track.id)
            })
    }

    private func matchedPresetName(for style: CaptionStyle) -> String? {
        BuiltInCaptionPresets.all.first { $0.style == style }?.name
    }

    // MARK: - Preset I/O

    private func importPreset(from url: URL, into trackID: CaptionTrack.ID) {
        do {
            let preset = try CaptionPresetIO.read(from: url)
            model.updateCaptionTrackDefaultStyle(preset.style, in: trackID)
            model.statusMessage = "Loaded preset “\(preset.name)”."
        } catch {
            model.statusMessage = "Could not import preset: \(error.localizedDescription)"
        }
    }

    private func exportPreset(for track: CaptionTrack) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = presetContentTypes
        panel.nameFieldStringValue = "\(track.name).\(CaptionPresetIO.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let preset = CaptionPresetV1(name: track.name, family: "custom", style: track.defaultStyle)
        do {
            try CaptionPresetIO.write(preset, to: url)
            model.statusMessage = "Exported preset to \(url.lastPathComponent)."
        } catch {
            model.statusMessage = "Could not export preset: \(error.localizedDescription)"
        }
    }

    // MARK: - Content types

    private var captionContentTypes: [UTType] {
        [UTType(filenameExtension: "srt") ?? .data,
         UTType(filenameExtension: "vtt") ?? .data]
    }

    private var presetContentTypes: [UTType] {
        [UTType(filenameExtension: CaptionPresetIO.fileExtension) ?? .data]
    }
}
