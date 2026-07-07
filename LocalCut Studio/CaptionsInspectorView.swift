import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit
import LocalCutCore

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
            if model.project.captionTracks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No caption tracks. Import an SRT/VTT or add an empty track to begin.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Import SRT/VTT…") { showSRTImporter = true }
                            .buttonStyle(.borderedProminent)
                        Button("Add Empty Track") { model.addEmptyCaptionTrack() }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Button("Import SRT/VTT…") { showSRTImporter = true }
                    Button("Add Empty Track") { model.addEmptyCaptionTrack() }
                    Spacer()
                }

                ForEach(model.project.captionTracks) { track in
                    trackBlock(track)
                }

                Text("Caption styling shows in preview and burned-in video exports; SRT/VTT sidecars stay plain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            TextField("Track name", text: Binding(
                get: { track.name },
                set: { model.renameCaptionTrack($0, in: track.id) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Caption track name")

            Toggle("Muted", isOn: Binding(
                get: { track.isMuted },
                set: { new in
                    // Route through performUndoable so mute toggles join the
                    // undo stack alongside every other caption edit.
                    model.setCaptionTrackMuted(new, in: track.id)
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
                    .accessibilityLabel("Remove caption track")
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
                compactSecondsField("Start",
                                    value: captionStartBinding(for: line, in: track),
                                    accessibilityLabel: "Caption line start")
                compactSecondsField("Duration",
                                    value: captionDurationBinding(for: line, in: track),
                                    accessibilityLabel: "Caption line duration")
                Spacer()
                Button(role: .destructive) {
                    model.removeCaptionLine(line.id, in: track.id)
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove line")
                    .accessibilityLabel("Remove caption line")
            }
            TextField("Caption text", text: Binding(
                get: { line.text },
                set: { newText in
                    var updated = line
                    updated.text = newText
                    model.updateCaptionLine(updated, in: track.id)
                }), axis: .vertical)
                .lineLimit(1...3)

            styleKeyframeEditor(line, in: track)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func styleKeyframeEditor(_ line: CaptionLine, in track: CaptionTrack) -> some View {
        let localTime = model.captionStyleLocalPlayheadTime(line.id, in: track.id)
        let styleValues = model.captionStyleKeyframeValues(line.id, in: track.id)
        DisclosureGroup {
            HStack {
                Text(localTime.map { "At \(TimeFormatting.timecode($0.seconds))" } ?? "Move playhead over this line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.captionStyleKeyframeCount(line.id, in: track.id)) keyframe(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ColorPicker("Fill", selection: captionStyleFillBinding(for: line, in: track),
                        supportsOpacity: true)
                .disabled(localTime == nil)
                .accessibilityLabel("Animated caption fill colour")

            LabeledSliderRow(
                label: "Scale",
                display: String(format: "%.2fx", styleValues.scale),
                value: captionStyleFloatBinding(\.scale, for: line, in: track),
                range: 0.1...4,
                step: 0.05,
                onEditingChanged: { editing in if !editing { model.commitCoalescedUndo() } })
                .disabled(localTime == nil)

            LabeledSliderRow(
                label: "X Offset",
                display: String(format: "%+.0f px", styleValues.offsetX),
                value: captionStyleFloatBinding(\.offsetX, for: line, in: track),
                range: -960...960,
                step: 1,
                onEditingChanged: { editing in if !editing { model.commitCoalescedUndo() } })
                .disabled(localTime == nil)

            LabeledSliderRow(
                label: "Y Offset",
                display: String(format: "%+.0f px", styleValues.offsetY),
                value: captionStyleFloatBinding(\.offsetY, for: line, in: track),
                range: -540...540,
                step: 1,
                onEditingChanged: { editing in if !editing { model.commitCoalescedUndo() } })
                .disabled(localTime == nil)

            LabeledSliderRow(
                label: "Opacity",
                display: "\(Int(styleValues.opacity * 100))%",
                value: captionStyleFloatBinding(\.opacity, for: line, in: track),
                range: 0...1,
                step: 0.01,
                onEditingChanged: { editing in if !editing { model.commitCoalescedUndo() } })
                .disabled(localTime == nil)

            LabeledSliderRow(
                label: "Letter Spacing",
                display: String(format: "%+.1f px", styleValues.letterSpacing),
                value: captionStyleFloatBinding(\.letterSpacing, for: line, in: track),
                range: -32...64,
                step: 0.5,
                onEditingChanged: { editing in if !editing { model.commitCoalescedUndo() } })
                .disabled(localTime == nil)

            HStack {
                Button {
                    model.seekToPreviousCaptionStyleKeyframe(line.id, in: track.id)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous caption style keyframe")
                .accessibilityLabel("Previous caption style keyframe")
                .disabled(localTime == nil)

                Button {
                    model.setCaptionStyleKeyframeValues(
                        styleValues,
                        lineID: line.id, in: track.id, coalesced: false)
                } label: {
                    Label(model.hasCaptionStyleKeyframeAtPlayhead(line.id, in: track.id) ? "Update" : "Add",
                          systemImage: "diamond.fill")
                }
                .disabled(localTime == nil)

                Button {
                    model.removeCaptionStyleKeyframeAtPlayhead(line.id, in: track.id)
                } label: {
                    Image(systemName: "minus.diamond")
                }
                .help("Remove caption style keyframe")
                .accessibilityLabel("Remove caption style keyframe")
                .disabled(!model.hasCaptionStyleKeyframeAtPlayhead(line.id, in: track.id))

                Button {
                    model.seekToNextCaptionStyleKeyframe(line.id, in: track.id)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next caption style keyframe")
                .accessibilityLabel("Next caption style keyframe")
                .disabled(localTime == nil)

                Spacer()

                Button("Clear") {
                    model.clearCaptionStyleKeyframes(line.id, in: track.id)
                }
                .disabled(model.captionStyleKeyframeCount(line.id, in: track.id) == 0)
            }
            .buttonStyle(.borderless)
        } label: {
            Text("Animated Style")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func compactSecondsField(_ label: String,
                                     value: Binding<Double>,
                                     accessibilityLabel: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .monospacedDigit()
                .accessibilityLabel(accessibilityLabel)
                .onSubmit { model.commitCoalescedUndo() }
            Text("s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func captionStartBinding(for line: CaptionLine, in track: CaptionTrack) -> Binding<Double> {
        Binding(
            get: { currentLine(line.id, in: track)?.range.start.seconds ?? line.range.start.seconds },
            set: { seconds in
                model.retimeCaptionLine(line.id, in: track.id, start: captionTime(seconds))
            })
    }

    private func captionDurationBinding(for line: CaptionLine, in track: CaptionTrack) -> Binding<Double> {
        Binding(
            get: { currentLine(line.id, in: track)?.range.duration.seconds ?? line.range.duration.seconds },
            set: { seconds in
                model.retimeCaptionLine(line.id, in: track.id, duration: captionTime(seconds))
            })
    }

    private func currentLine(_ id: CaptionLine.ID, in track: CaptionTrack) -> CaptionLine? {
        track.lines.first { $0.id == id }
    }

    private func captionTime(_ seconds: Double) -> CMTime {
        let finite = seconds.isFinite ? seconds : 0
        return CMTime(seconds: finite, preferredTimescale: 600)
    }

    private func captionStyleFloatBinding(
        _ keyPath: WritableKeyPath<CaptionStyleKeyframeValues, Float>,
        for line: CaptionLine,
        in track: CaptionTrack
    ) -> Binding<Float> {
        Binding(
            get: { model.captionStyleKeyframeValues(line.id, in: track.id)[keyPath: keyPath] },
            set: { value in
                var values = model.captionStyleKeyframeValues(line.id, in: track.id)
                values[keyPath: keyPath] = value
                model.setCaptionStyleKeyframeValues(values, lineID: line.id, in: track.id)
            })
    }

    private func captionStyleFillBinding(for line: CaptionLine,
                                         in track: CaptionTrack) -> Binding<Color> {
        Binding(
            get: {
                Color(cgColor: model.captionStyleKeyframeValues(line.id, in: track.id).fill.cgColor)
            },
            set: { color in
                var values = model.captionStyleKeyframeValues(line.id, in: track.id)
                values.fill = rgbaColour(from: color)
                model.setCaptionStyleKeyframeValues(values, lineID: line.id, in: track.id)
            })
    }

    private func rgbaColour(from color: Color) -> RGBAColour {
        let ns = NSColor(color)
        guard let converted = ns.usingColorSpace(.sRGB) else {
            return .white
        }
        return RGBAColour(
            red: Float(converted.redComponent),
            green: Float(converted.greenComponent),
            blue: Float(converted.blueComponent),
            alpha: Float(converted.alphaComponent))
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
