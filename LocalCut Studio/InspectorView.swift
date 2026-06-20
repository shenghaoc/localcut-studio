import SwiftUI
import AVFoundation

/// Context-sensitive properties for the current selection plus project-wide
/// render settings.
struct InspectorView: View {
    @Bindable var model: EditorModel

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
                if let clip = model.selectedClip {
                    clipSection(clip)
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
                        set: { newValue in model.updateSelectedClip { $0.opacity = Float(newValue) } }),
                    in: 0...1)
            }
        }
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
            set: { model.project.renderSize = $0; Task { await model.rebuild() } })
    }

    private var frameRateBinding: Binding<Double> {
        Binding(
            get: { model.project.frameRate },
            set: { model.project.frameRate = $0; Task { await model.rebuild() } })
    }
}
