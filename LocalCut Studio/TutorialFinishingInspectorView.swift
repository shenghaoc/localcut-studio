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

    var body: some View {
        Group {
            silenceDetectionSection
                .sheet(isPresented: $showSilenceReview) {
                    SilenceReviewSheet(model: model, isPresented: $showSilenceReview)
                }
            keystrokeOverlaySection
            chapterExportSection
            captionPresetSection
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
                    .accessibilityLabel("Open Threshold")
                    .accessibilityValue("\(Int(silenceParams.openThresholdDB)) dBFS")
                    .frame(maxWidth: 160)
                    Text("\(Int(silenceParams.openThresholdDB)) dBFS")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                LabeledContent("Close Threshold") {
                    Slider(value: $silenceParams.closeThresholdDB, in: -50 ... -10, step: 1) {
                        Text("dBFS")
                    }
                    .accessibilityLabel("Close Threshold")
                    .accessibilityValue("\(Int(silenceParams.closeThresholdDB)) dBFS")
                    .frame(maxWidth: 160)
                    Text("\(Int(silenceParams.closeThresholdDB)) dBFS")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                LabeledContent("Min Duration") {
                    HStack {
                        Slider(value: Binding(
                            get: { silenceParams.minimumSilenceDuration.seconds },
                            set: { silenceParams.minimumSilenceDuration = CMTime(seconds: $0, preferredTimescale: 600) }
                        ), in: 0.1 ... 5.0, step: 0.1) {
                            Text("seconds")
                        }
                        .accessibilityLabel("Min Duration")
                        .accessibilityValue(String(format: "%.1f seconds", silenceParams.minimumSilenceDuration.seconds))
                        .frame(maxWidth: 120)
                        Text(String(format: "%.1fs", silenceParams.minimumSilenceDuration.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
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
                        .accessibilityLabel("Padding")
                        .accessibilityValue(String(format: "%.2f seconds", silenceParams.padding.seconds))
                        .frame(maxWidth: 120)
                        Text(String(format: "%.2fs", silenceParams.padding.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                HStack {
                    Button("Detect Silences") {
                        model.runSilenceDetection(parameters: silenceParams)
                    }
                    .disabled(!model.canRunSilenceDetection)
                    .help("Analyse audio tracks for silent passages based on the thresholds above")

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
                    .help("Create a visual keystroke overlay from the imported event log")

                    ForEach(model.project.keystrokeOverlayClips) { clip in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(clip.events.count) keystroke(s)")
                                    .font(.caption)
                                Text("Session \(clip.sourceSessionID.uuidString.prefix(8))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.removeKeystrokeOverlay(id: clip.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove keystroke overlay")
                            .help("Remove this keystroke overlay from the timeline")
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
                        .help("Change every timeline marker to a chapter marker for YouTube export")
                    }

                    if !issues.isEmpty {
                        ForEach(issues, id: \.self) { issue in
                            Label(issue.localizedDescription, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if model.hasRepairableChapterShortSpans {
                        HStack {
                            Button(ChapterShortSpanRepairStrategy.merge.displayName) {
                                model.repairChapterShortSpans(strategy: .merge)
                            }
                            Button(ChapterShortSpanRepairStrategy.drop.displayName) {
                                model.repairChapterShortSpans(strategy: .drop)
                            }
                        }
                    }

                    Button("Export Chapter Sidecar") {
                        showChapterExport = true
                    }
                    .disabled(!model.hasChapterMarkers || !issues.isEmpty)
                    .help("Save chapter timestamps to a plain-text sidecar file")
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
            } else if case .failure(let error) = result {
                model.statusMessage = "Chapter sidecar export failed: \(error.localizedDescription)"
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
                    .help("Apply the built-in tutorial caption style preset to the first caption track")
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
        let issues = YouTubeChapterValidator.validate(chapters, projectDuration: projectDuration)
        guard issues.isEmpty else {
            throw ChapterSidecarDocumentError.validationFailed(issues)
        }
        let content = YouTubeChapterValidator.format(chapters)
        let data = Data(content.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

private enum ChapterSidecarDocumentError: LocalizedError {
    case validationFailed([ChapterExportIssue])

    var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            "Fix chapter markers before export: \(issues.map(\.localizedDescription).joined(separator: " "))"
        }
    }
}
