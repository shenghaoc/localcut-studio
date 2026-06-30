import SwiftUI
import CoreMedia
import UniformTypeIdentifiers
import LocalCutCore

// MARK: - Tutorial Finishing Inspector

/// Inspector section for Phase 44 tutorial finishing tools: silence detection,
/// keystroke overlay, chapter export, and caption preset.
struct TutorialFinishingInspectorView: View {
    @Bindable var model: EditorModel
    @State private var showSilenceReview = false
    @State private var showChapterExport = false
    @State private var silenceParams = SilenceDetectionParameters()
    @State private var chapterExportResult: ChapterExportResult?

    var body: some View {
        Section("Tutorial Finishing") {
            silenceDetectionSection
            keystrokeOverlaySection
            chapterExportSection
            captionPresetSection
        }
        .sheet(isPresented: $showSilenceReview) {
            SilenceReviewSheet(model: model, isPresented: $showSilenceReview)
        }
    }

    // MARK: - Silence Detection

    @ViewBuilder
    private var silenceDetectionSection: some View {
        DisclosureGroup("Silence Detection") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Open Threshold") {
                    Slider(value: $silenceParams.openThresholdDB, in: -60 ... -20, step: 1) {
                        Text("dBFS")
                    }
                    .frame(maxWidth: 160)
                    Text("\(Int(silenceParams.openThresholdDB)) dBFS")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Close Threshold") {
                    Slider(value: $silenceParams.closeThresholdDB, in: -50 ... -10, step: 1) {
                        Text("dBFS")
                    }
                    .frame(maxWidth: 160)
                    Text("\(Int(silenceParams.closeThresholdDB)) dBFS")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Min Duration") {
                    HStack {
                        Slider(value: Binding(
                            get: { silenceParams.minimumSilenceDuration.seconds },
                            set: { silenceParams.minimumSilenceDuration = CMTime(seconds: $0, preferredTimescale: 600) }
                        ), in: 0.1 ... 5.0, step: 0.1) {
                            Text("seconds")
                        }
                        .frame(maxWidth: 120)
                        Text(String(format: "%.1fs", silenceParams.minimumSilenceDuration.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Padding") {
                    HStack {
                        Slider(value: Binding(
                            get: { silenceParams.padding.seconds },
                            set: { silenceParams.padding = CMTime(seconds: $0, preferredTimescale: 600) }
                        ), in: 0 ... 1.0, step: 0.05) {
                            Text("seconds")
                        }
                        .frame(maxWidth: 120)
                        Text(String(format: "%.2fs", silenceParams.padding.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Detect Silences") {
                        model.runSilenceDetection(parameters: silenceParams)
                    }
                    .disabled(model.project.audioTracks.allSatisfy(\.clips.isEmpty))

                    if model.hasSilenceProposals {
                        Button("Review (\(model.silenceProposals.count))") {
                            showSilenceReview = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Keystroke Overlay

    @ViewBuilder
    private var keystrokeOverlaySection: some View {
        DisclosureGroup("Keystroke Overlay") {
            VStack(alignment: .leading, spacing: 8) {
                if model.project.screencastEventLogs.isEmpty {
                    Text("No event log available. Record with event capture enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Add Keystroke Overlay") {
                        model.addKeystrokeOverlayFromEventLog()
                    }

                    ForEach(model.keystrokeOverlayClips) { clip in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(clip.events.count) keystroke(s)")
                                    .font(.caption)
                                Text("Session \(clip.sourceSessionID.uuidString.prefix(8))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.removeKeystrokeOverlay(id: clip.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Chapter Export

    @ViewBuilder
    private var chapterExportSection: some View {
        DisclosureGroup("Chapter Export") {
            VStack(alignment: .leading, spacing: 8) {
                let issues = model.chapterValidationIssues

                if model.project.markers.isEmpty {
                    Text("Add timeline markers and set them as chapters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let chapterCount = model.project.markers.filter { $0.kind == .chapter }.count
                    Text("\(chapterCount) chapter marker(s), \(model.project.markers.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !model.hasChapterMarkers {
                        Button("Convert All Markers to Chapters") {
                            model.convertAllMarkersToChapters()
                        }
                    }

                    if !issues.isEmpty {
                        ForEach(issues.indices, id: \.self) { i in
                            Label(issues[i].localizedDescription, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Button("Export Chapter Sidecar") {
                        showChapterExport = true
                    }
                    .disabled(!model.hasChapterMarkers)
                }
            }
        }
        .fileExporter(
            isPresented: $showChapterExport,
            document: ChapterSidecarDocument(markers: model.project.markers,
                                             projectDuration: model.project.duration),
            contentType: .plainText,
            defaultFilename: "\(model.project.name).chapters"
        ) { result in
            if case .success(let url) = result {
                model.statusMessage = "Chapter sidecar exported to \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Caption Preset

    @ViewBuilder
    private var captionPresetSection: some View {
        DisclosureGroup("Tutorial Caption Preset") {
            VStack(alignment: .leading, spacing: 8) {
                if model.project.captionTracks.isEmpty {
                    Text("Add a caption track to apply the tutorial preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Apply Tutorial Preset") {
                        applyTutorialPreset()
                    }
                }
            }
        }
    }

    private func applyTutorialPreset() {
        guard let preset = BuiltInCaptionPresets.all.first(where: { $0.family == "tutorial" }) else { return }
        guard let track = model.project.captionTracks.first else { return }
        model.updateCaptionTrackDefaultStyle(preset.style, in: track.id)
        model.statusMessage = "Applied Tutorial caption preset."
    }
}

// MARK: - Chapter Sidecar Document

/// A file document wrapper for the chapter sidecar export.
struct ChapterSidecarDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let markers: [TimelineMarker]
    let projectDuration: CMTime

    init(markers: [TimelineMarker], projectDuration: CMTime) {
        self.markers = markers
        self.projectDuration = projectDuration
    }

    init(configuration: FileDocumentReadConfiguration) throws {
        markers = []
        projectDuration = .zero
    }

    func fileWrapper(configuration: FileDocumentWriteConfiguration) throws -> FileWrapper {
        let chapters = YouTubeChapterValidator.chapters(from: markers, projectDuration: projectDuration)
        let content = YouTubeChapterValidator.format(chapters)
        let data = Data(content.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}
