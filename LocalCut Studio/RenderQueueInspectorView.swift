import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit
import LocalCutCore

/// Inspector section for the render queue: a list of built-in presets with
/// one-tap "Add to Queue" buttons, followed by the live queue with status
/// pills + cancel buttons.
///
/// The view mirrors `CaptionsInspectorView`'s shape so the inspector reads as
/// one consistent column.
struct RenderQueueInspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Renders") {
            presetList
            queueList
        }
    }

    // MARK: - Presets

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(BuiltInExportPresets.all) { preset in
                presetRow(preset)
            }
        }
    }

    private func presetRow(_ preset: ExportPreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(preset.name)
                    Text(presetSubtitle(preset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button("Add to Queue…") {
                    addToQueue(preset: preset)
                }
                .controlSize(.small)
                .help("Pick an output file and enqueue a render with this preset.")
                .accessibilityLabel("Add \(preset.name) to queue")
            }
            if preset.projectAspect != model.project.aspect {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text("Project is \(model.project.aspect.displayName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Switch to \(preset.projectAspect.displayName)") {
                        model.setProjectAspect(preset.projectAspect)
                    }
                    .controlSize(.mini)
                    .help("Switch the project canvas before queueing this preset.")
                }
            }
        }
    }

    /// One-line summary under the preset name: container • codec • size • aspect • bitrate.
    private func presetSubtitle(_ preset: ExportPreset) -> String {
        let codec: String
        switch preset.videoCodec {
        case AVVideoCodecType.h264.rawValue: codec = "H.264"
        case AVVideoCodecType.hevc.rawValue: codec = "HEVC"
        case AVVideoCodecType.proRes422HQ.rawValue: codec = "ProRes 422 HQ"
        case AVVideoCodecType.proRes422.rawValue: codec = "ProRes 422"
        case AVVideoCodecType.proRes4444.rawValue: codec = "ProRes 4444"
        default: codec = preset.videoCodec.uppercased()
        }
        let size = "\(Int(preset.targetSize.width))×\(Int(preset.targetSize.height))"
        let container = preset.defaultFilenameExtension.uppercased()
        return "\(container) • \(codec) • \(size) • \(preset.aspect.displayName) • \(preset.bitrate.displayName)"
    }

    // MARK: - Queue

    @ViewBuilder
    private var queueList: some View {
        if model.renderQueue.jobs.isEmpty {
            Text("No renders queued. Add a preset above to queue a render.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if model.renderQueue.isRunning {
                    ProgressView(value: model.renderQueue.totalProgress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Overall render progress: \(Int(model.renderQueue.totalProgress * 100))%")
                }
                ForEach(model.renderQueue.jobs) { job in
                    queueRow(job)
                }
                HStack {
                    Spacer()
                    Button("Clear Completed") {
                        model.renderQueue.clearCompleted()
                    }
                    .controlSize(.small)
                    .disabled(!model.renderQueue.jobs.contains(where: { $0.isTerminal }))
                }
            }
        }
    }

    private func queueRow(_ job: QueueJob) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading) {
                    Text(job.outputDisplayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.preset.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusPill(job)
                if job.status == .queued || job.status == .running {
                    Button {
                        model.renderQueue.cancel(jobID: job.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel render")
                    .accessibilityLabel("Cancel \(job.outputDisplayName)")
                }
                if job.status == .completed {
                    Button {
                        revealInFinder(job)
                    } label: {
                        Image(systemName: "magnifyingglass.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(job.outputDisplayName) in Finder")
                }
                if job.status == .failed || job.status == .cancelled {
                    Button {
                        model.renderQueue.retry(jobID: job.id)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Retry this render against the same destination")
                    .accessibilityLabel("Retry \(job.outputDisplayName)")
                }
            }
            // Surface the underlying failure so the user can act on it
            // rather than guessing why the pill went red (codex P2).
            if job.status == .failed, let message = job.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("Failure reason: \(message)")
            }
        }
        .padding(.vertical, 2)
    }

    /// Status badge: a coloured capsule + label. For `running`, includes the
    /// percentage.
    private func statusPill(_ job: QueueJob) -> some View {
        let label: String
        let colour: Color
        switch job.status {
        case .queued: label = "Queued"; colour = .secondary
        case .running: label = "Running \(Int(job.progress * 100))%"; colour = .lcAccent
        case .completed: label = "Completed"; colour = .green
        case .cancelled: label = "Cancelled"; colour = .secondary
        case .failed: label = "Failed"; colour = .red
        }
        return Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
            .accessibilityLabel("Status: \(job.status.displayName)")
    }

    /// Reveals a completed render in Finder. Resolving the bookmark to a URL is
    /// enough for `activateFileViewerSelecting`; no security-scoped read needed.
    private func revealInFinder(_ job: QueueJob) {
        guard let url = model.renderQueue.outputURL(forJobID: job.id) else {
            model.statusMessage = "Could not locate \(job.outputDisplayName)."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Add to queue

    /// Opens an `NSSavePanel` filtered to the preset's container, captures a
    /// security-scoped bookmark for the chosen destination folder, and
    /// enqueues a job carrying the current project's snapshot.
    private func addToQueue(preset: ExportPreset) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: preset.defaultFilenameExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(model.project.name).\(preset.defaultFilenameExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bookmark = RenderQueue.outputBookmark(for: url) else {
            model.statusMessage = "Could not access \(url.lastPathComponent)."
            return
        }

        let snapshot = ProjectDocument(project: model.project, queueBundleURL: model.documentURL)
        let job = QueueJob(
            preset: preset,
            outputBookmark: bookmark,
            outputDisplayName: url.lastPathComponent,
            projectSnapshot: snapshot)
        _ = model.renderQueue.enqueue(job)
        model.statusMessage = "Queued \(preset.name) → \(url.lastPathComponent)."
    }
}
