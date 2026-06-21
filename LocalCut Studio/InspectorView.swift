import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Context-sensitive properties for the current selection plus project-wide
/// render settings.
struct InspectorView: View {
    @Bindable var model: EditorModel
    @State private var showLUTImporter = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            Form {
                if let transition = model.selectedTransition {
                    transitionSection(transition)
                } else if let clip = model.selectedClip {
                    clipSection(clip)
                    if clipIsVideo(clip) {
                        colourSection
                    }
                } else if let media = model.selectedMedia {
                    mediaSection(media)
                } else {
                    Section {
                        Text("Select a clip or media item.")
                            .foregroundStyle(.secondary)
                    }
                }

                projectSection
            }
            .formStyle(.grouped)
        }
        .fileImporter(
            isPresented: $showLUTImporter,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importLUT(url: url)
            }
        }
    }

    private func clipIsVideo(_ clip: Clip) -> Bool {
        model.track(for: clip.id)?.kind == .video
    }

    @ViewBuilder
    private func clipSection(_ clip: Clip) -> some View {
        Section("Clip") {
            LabeledContent("Start", value: TimeFormatting.timecode(clip.timelineStart.seconds))
            LabeledContent("Duration", value: TimeFormatting.timecode(clip.duration.seconds))

            VStack(alignment: .leading) {
                Text("Opacity \(Int(clip.opacity * 100))%")
                Slider(
                    value: Binding(
                        get: { Double(clip.opacity) },
                        set: { newValue in model.updateSelectedClipCoalesced("Adjust Opacity") { $0.opacity = Float(newValue) } }),
                    in: 0...1)
            }
        }
    }

    // MARK: - Transition

    @ViewBuilder
    private func transitionSection(_ transition: Transition) -> some View {
        Section("Transition") {
            Picker("Type", selection: transitionTypeBinding) {
                ForEach(TransitionType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            VStack(alignment: .leading) {
                // Show the effective (clamped) duration so the label can't exceed
                // the slider's ceiling after a neighbour is trimmed shorter.
                Text("Duration \(String(format: "%.2f s", min(transition.duration.seconds, maxTransitionSeconds)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: transitionDurationBinding, in: minTransitionSeconds...maxTransitionSeconds)
            }

            Button(role: .destructive) {
                model.removeSelectedTransition()
            } label: {
                Label("Remove Transition", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    /// Shortest allowed transition (one render frame at the project frame rate).
    private var minTransitionSeconds: Double { 1.0 / max(1, model.project.frameRate) }

    /// Longest allowed transition: the available overlap, never below the min.
    private var maxTransitionSeconds: Double {
        max(model.selectedTransitionMaxDuration.seconds, minTransitionSeconds + 0.01)
    }

    private var transitionTypeBinding: Binding<TransitionType> {
        Binding(
            get: { model.selectedTransition?.type ?? .crossDissolve },
            set: { newValue in model.updateSelectedTransition { $0.type = newValue } })
    }

    private var transitionDurationBinding: Binding<Double> {
        Binding(
            get: { min(model.selectedTransition?.duration.seconds ?? 0, maxTransitionSeconds) },
            set: { newValue in
                model.updateSelectedTransition(coalesced: true) {
                    $0.duration = CMTime(seconds: newValue, preferredTimescale: 600)
                }
            })
    }

    // MARK: - Colour Grading

    @ViewBuilder
    private var colourSection: some View {
        Section("Colour") {
            colourSlider(label: "Exposure", value: colourGradeBinding(\.exposure),
                         range: Float(-2)...Float(2), step: Float(0.05), display: String(format: "%+.2f", model.selectedClipGrade.exposure))
            colourSlider(label: "Contrast", value: colourGradeBinding(\.contrast),
                         range: Float(0.5)...Float(1.5), step: Float(0.05), display: String(format: "%.2f", model.selectedClipGrade.contrast))
            colourSlider(label: "Saturation", value: colourGradeBinding(\.saturation),
                         range: Float(0)...Float(2), step: Float(0.05), display: String(format: "%.2f", model.selectedClipGrade.saturation))
            colourSlider(label: "Temp offset", value: colourGradeBinding(\.temperatureOffset),
                         range: Float(-4000)...Float(4000), step: Float(100), display: "\(String(format: "%+.0f", model.selectedClipGrade.temperatureOffset))K")
            colourSlider(label: "Tint offset", value: colourGradeBinding(\.tintOffset),
                         range: Float(-150)...Float(150), step: Float(10), display: String(format: "%+.0f", model.selectedClipGrade.tintOffset))

            HStack {
                Button("Import LUT…") { showLUTImporter = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button("Reset") { model.resetClipColourEffects() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func colourSlider(label: String, value: Binding<Float>, range: ClosedRange<Float>, step: Float, display: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(label)  \(display)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step)
        }
    }

    private func colourGradeBinding(_ keyPath: WritableKeyPath<ColourGrade, Float>) -> Binding<Float> {
        Binding(
            get: { model.selectedClipGrade[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedClipCoalesced("Adjust Colour") { clip in
                    if let effectIndex = clip.effects.firstIndex(where: {
                        if case .colourGrade = $0 { return true }; return false
                    }) {
                        if case .colourGrade(var grade) = clip.effects[effectIndex] {
                            grade[keyPath: keyPath] = newValue
                            grade.clamp()
                            clip.effects[effectIndex] = .colourGrade(grade)
                        }
                    } else {
                        var grade = ColourGrade()
                        grade[keyPath: keyPath] = newValue
                        grade.clamp()
                        clip.effects.append(.colourGrade(grade))
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func mediaSection(_ media: MediaItem) -> some View {
        Section("Media") {
            LabeledContent("Name", value: media.name)
            LabeledContent("Duration", value: TimeFormatting.timecode(media.durationSeconds))
            if media.hasVideo {
                LabeledContent("Size", value: "\(Int(media.naturalSize.width))×\(Int(media.naturalSize.height))")
            }
            LabeledContent("Tracks", value: [
                media.hasVideo ? "Video" : nil,
                media.hasAudio ? "Audio" : nil
            ].compactMap { $0 }.joined(separator: ", "))
        }
    }

    private var projectSection: some View {
        Section("Project") {
            Picker("Resolution", selection: resolutionBinding) {
                Text("1920 × 1080").tag(CGSize(width: 1920, height: 1080))
                Text("1280 × 720").tag(CGSize(width: 1280, height: 720))
                Text("3840 × 2160").tag(CGSize(width: 3840, height: 2160))
                Text("1080 × 1920 (Vertical)").tag(CGSize(width: 1080, height: 1920))
            }
            Picker("Frame Rate", selection: frameRateBinding) {
                Text("24 fps").tag(24.0)
                Text("30 fps").tag(30.0)
                Text("60 fps").tag(60.0)
            }
        }
    }

    private var resolutionBinding: Binding<CGSize> {
        Binding(
            get: { model.project.renderSize },
            set: { model.setRenderSize($0) })
    }

    private var frameRateBinding: Binding<Double> {
        Binding(
            get: { model.project.frameRate },
            set: { model.setFrameRate($0) })
    }
}
