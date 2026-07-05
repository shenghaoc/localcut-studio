import Foundation
import AppKit
import UniformTypeIdentifiers
import LocalCutCore

/// AppKit panel/prompt glue for the document menu commands and the close flow.
/// Kept apart from the pure persistence logic so the model's save/open/undo code
/// stays free of panel presentation.
extension EditorModel {

    // MARK: - Menu actions

    /// File ▸ New — offers to save first, then resets to an empty project.
    func requestNew() {
        Task {
            guard !blockDocumentCommandWhileRecording() else { return }
            guard await confirmSaveIfNeeded() else { return }
            newDocument()
        }
    }

    /// File ▸ Open — offers to save first, then presents an open panel that
    /// accepts both `.lcstudio` (legacy single-file) and `.lcbundle` (package).
    func requestOpen() {
        Task {
            guard !blockDocumentCommandWhileRecording() else { return }
            guard await confirmSaveIfNeeded() else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.lcStudioProjectBundle, .lcStudioProject]
            panel.allowsMultipleSelection = false
            // `.lcbundle` conforms to `.package`, so the panel treats it as a
            // single double-clickable item. We do NOT enable
            // `canChooseDirectories`: doing so lets the user pick arbitrary
            // folders (Desktop, Documents) that have no `project.json` and
            // would fail to open.
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            let response = await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response)
                }
            }
            guard response == .OK, let url = panel.url else { return }
            await open(url: url)
        }
    }

    func requestOpenRecent(_ url: URL) {
        Task {
            guard !blockDocumentCommandWhileRecording() else { return }
            guard await confirmSaveIfNeeded() else { return }
            await open(url: url)
        }
    }

    /// File ▸ Import… — presents an open panel for media and appends the picks to
    /// the library. Mirrors the Media bin's `+` affordance so importing has a
    /// menu home and a standard ⌘I shortcut. Uses the Media bin's default of
    /// copying imports into the bundle.
    func requestImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent,
                                     .audio, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { @MainActor [weak self] response in
            guard response == .OK, let self, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { await self.importMedia(urls: urls, wantsBundling: self.copyImportsIntoBundle) }
        }
    }

    /// File ▸ Export… — presents the same save panel the toolbar Export button
    /// uses and queues a render with the default preset, so the app's primary
    /// output action has a menu home and a ⇧⌘E shortcut.
    func requestExport() {
        guard totalDuration > 0 else { return }
        guard resolveChapterMarkersBeforeExport() else { return }
        let preset = BuiltInExportPresets.defaultPreset
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: preset.defaultFilenameExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(project.name).\(preset.defaultFilenameExtension)"
        panel.canCreateDirectories = true
        panel.begin { @MainActor [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.export(to: url) }
        }
    }

    /// File ▸ Export Timeline (.otio) — serializes the project to OpenTimelineIO
    /// interchange format and writes to the user-selected location.
    func requestExportOtio() {
        guard totalDuration > 0 else { return }
        let panel = NSSavePanel()
        let otioType = UTType(filenameExtension: "otio") ?? .json
        panel.allowedContentTypes = [otioType]
        panel.nameFieldStringValue = "\(project.name).otio"
        panel.canCreateDirectories = true
        panel.begin { @MainActor [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.exportOtio(to: url)
        }
    }

    private func exportOtio(to url: URL) {
        let document = documentController.makeDocumentForSave(forBundle: false, model: self)
        // Snapshot media names before the Sendable closure.
        let mediaNames: [UUID: String] = Dictionary(
            uniqueKeysWithValues: project.mediaItems.map { ($0.id, $0.name) })
        let options = OtioSerializationOptions(
            bundleMode: false,
            resolveTargetUrl: { mediaID in
                mediaNames[mediaID] ?? mediaID.uuidString
            })
        let (json, warnings) = serializeTimelineToOtio(document, options: options)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            if warnings.isEmpty {
                statusMessage = "Exported \(url.lastPathComponent)."
            } else {
                let warningText = warnings.prefix(3).map(\.description).joined(separator: "; ")
                statusMessage = "Exported \(url.lastPathComponent) — \(warningText)"
            }
        } catch {
            statusMessage = "OTIO export failed: \(error.localizedDescription)"
        }
    }

    /// File ▸ Export EDL (.edl) — serializes the selected video track to CMX3600
    /// EDL format. If multiple video tracks exist, presents a track picker.
    func requestExportEdl() {
        guard totalDuration > 0 else { return }
        guard !project.videoTracks.isEmpty else {
            statusMessage = "No video tracks to export."
            return
        }

        // If multiple video tracks, show a picker.
        if project.videoTracks.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Choose Video Track for EDL Export"
            alert.informativeText = "CMX3600 EDL exports a single video track."
            for (index, track) in project.videoTracks.enumerated() {
                alert.addButton(withTitle: "\(track.name) (V\(index + 1))")
            }
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            let trackIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard trackIndex >= 0, trackIndex < project.videoTracks.count else { return }
            exportEdl(trackIndex: trackIndex)
        } else {
            exportEdl(trackIndex: 0)
        }
    }

    private func exportEdl(trackIndex: Int) {
        let panel = NSSavePanel()
        let edlType = UTType(filenameExtension: "edl") ?? .plainText
        panel.allowedContentTypes = [edlType]
        panel.nameFieldStringValue = "\(project.name).edl"
        panel.canCreateDirectories = true
        panel.begin { @MainActor [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.exportEdl(to: url, trackIndex: trackIndex)
        }
    }

    private func exportEdl(to url: URL, trackIndex: Int) {
        let document = documentController.makeDocumentForSave(forBundle: false, model: self)
        let options = EdlSerializationOptions(
            title: project.name,
            videoTrackIndex: trackIndex)
        let (edl, warnings) = serializeTimelineToEdl(document, options: options)
        do {
            try edl.write(to: url, atomically: true, encoding: .utf8)
            if warnings.isEmpty {
                statusMessage = "Exported \(url.lastPathComponent)."
            } else {
                let warningText = warnings.prefix(3).map(\.description).joined(separator: "; ")
                statusMessage = "Exported \(url.lastPathComponent) — \(warningText)"
            }
        } catch {
            statusMessage = "EDL export failed: \(error.localizedDescription)"
        }
    }

    private func resolveChapterMarkersBeforeExport() -> Bool {
        guard hasChapterMarkers else { return true }
        let issues = chapterValidationIssues
        guard !issues.isEmpty else { return true }

        let hasShortSpanIssue = issues.contains { issue in
            if case .spanTooShort = issue { return true }
            return false
        }
        guard hasShortSpanIssue else {
            presentChapterExportBlockedAlert(issues: issues)
            return false
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Resolve chapter markers before export"
        alert.informativeText = chapterIssueSummary(issues)
        alert.addButton(withTitle: ChapterShortSpanRepairStrategy.merge.displayName)
        alert.addButton(withTitle: ChapterShortSpanRepairStrategy.drop.displayName)
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            repairChapterShortSpans(strategy: .merge)
        case .alertSecondButtonReturn:
            repairChapterShortSpans(strategy: .drop)
        default:
            statusMessage = "Export cancelled until chapter markers are fixed."
            return false
        }

        let remainingIssues = chapterValidationIssues
        guard remainingIssues.isEmpty else {
            presentChapterExportBlockedAlert(issues: remainingIssues)
            return false
        }
        return true
    }

    private func presentChapterExportBlockedAlert(issues: [ChapterExportIssue]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Fix chapter markers before export"
        alert.informativeText = chapterIssueSummary(issues)
        alert.addButton(withTitle: "OK")
        alert.runModal()
        statusMessage = "Export blocked by \(issues.count) chapter validation issue(s)."
    }

    private func chapterIssueSummary(_ issues: [ChapterExportIssue]) -> String {
        let visibleIssues = issues.prefix(6).map(\.localizedDescription)
        var summary = visibleIssues.joined(separator: "\n")
        let remainingCount = issues.count - visibleIssues.count
        if remainingCount > 0 {
            summary += "\n\(remainingCount) more issue(s)."
        }
        return summary
    }

    /// File ▸ Save — writes to the current URL, or prompts for one if unsaved.
    func requestSave() {
        Task {
            guard !blockDocumentCommandDuringCloseSave() else { return }
            if documentURL != nil {
                await save()
            } else if let url = runSavePanel() {
                await saveAs(url: url)
            }
        }
    }

    /// File ▸ Save As — always prompts for a new location.
    func requestSaveAs() {
        Task {
            guard !blockDocumentCommandDuringCloseSave() else { return }
            if let url = runSavePanel() { await saveAs(url: url) }
        }
    }

    // MARK: - Panels & prompts

    /// Presents a save panel that defaults to `.lcbundle` (the package format)
    /// but also accepts `.lcstudio` for the legacy single-file shape. Returns
    /// the chosen URL.
    func runSavePanel() -> URL? {
        let panel = NSSavePanel()
        // Bundle first so it's the default content type for new documents.
        panel.allowedContentTypes = [.lcStudioProjectBundle, .lcStudioProject]
        panel.nameFieldStringValue = "\(project.name).\(ProjectBundleLayout.fileExtension)"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// File ▸ Convert to Bundle… — writes a fresh `.lcbundle` alongside the
    /// existing `.lcstudio`, leaving the original untouched (R4.2 / R4.3).
    func requestConvertToBundle() {
        guard canConvertToBundle else { return }
        Task {
            guard !blockDocumentCommandDuringCloseSave() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.lcStudioProjectBundle]
            panel.nameFieldStringValue = "\(project.name).\(ProjectBundleLayout.fileExtension)"
            // Default the panel to the directory containing the current document.
            if let docURL = documentURL {
                panel.directoryURL = docURL.deletingLastPathComponent()
            }
            panel.canCreateDirectories = true
            let response = await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response)
                }
            }
            guard response == .OK, let url = panel.url else { return }
            await convertToBundle(to: url)
        }
    }

    /// If there are unsaved changes, asks whether to save. Returns `true` if the
    /// caller may proceed (saved or discarded) and `false` if the user cancelled.
    func confirmSaveIfNeeded() async -> Bool {
        guard !blockDocumentCommandDuringCloseSave() else { return false }
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(project.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:        // Save
            if documentURL != nil {
                await save()
                return !isDirty
            }
            guard let url = runSavePanel() else { return false }
            await saveAs(url: url)
            return !isDirty
        case .alertSecondButtonReturn:       // Don't Save
            return true
        default:                             // Cancel
            return false
        }
    }

    /// Synchronous variant for `windowShouldClose`, which must return a decision
    /// immediately. Returns `true` if the window may close.
    func confirmClose(window: NSWindow) -> Bool {
        guard !blockDocumentCommandDuringCloseSave() else { return false }
        guard !hasActiveRecordingLifecycle else {
            statusMessage = recordingLifecycleBlockMessage(action: "closing the window")
            return false
        }
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(project.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:        // Save
            guard let url = documentURL ?? runSavePanel() else { return false }
            closeSaveInProgress = true
            statusMessage = "Saving \(url.lastPathComponent) before closing…"
            Task { @MainActor [weak window] in
                if documentURL == nil {
                    await saveAs(url: url)
                } else {
                    await save()
                }
                let shouldClose = !isDirty
                closeSaveInProgress = false
                if shouldClose {
                    window?.performClose(nil)
                }
            }
            return false
        case .alertSecondButtonReturn:       // Don't Save
            return true
        default:                             // Cancel
            return false
        }
    }

    private func blockDocumentCommandDuringCloseSave() -> Bool {
        guard closeSaveInProgress else { return false }
        statusMessage = "Finish saving before closing…"
        return true
    }

    /// Document lifecycle commands (New/Open) must not run mid-recording: the
    /// session reset would tear down media access while capture writers keep
    /// running, and a later Stop could land the take into the wrong project.
    private func blockDocumentCommandWhileRecording() -> Bool {
        guard hasActiveRecordingLifecycle else { return false }
        statusMessage = recordingLifecycleBlockMessage(action: "switching projects")
        return true
    }

    private var hasActiveRecordingLifecycle: Bool {
        isCountdownActive || isRecording || isPaused || isStartingRecording || isPausingRecording || isStoppingRecording
    }

    private func recordingLifecycleBlockMessage(action: String) -> String {
        if isCountdownActive {
            return "Cancel the countdown before \(action)."
        }
        if isStartingRecording {
            return "Wait for the recording to start before \(action)."
        }
        if isPausingRecording {
            return "Finish pausing the recording before \(action)."
        }
        if isStoppingRecording {
            return "Finish stopping the recording before \(action)."
        }
        if isPaused {
            return "Resume and stop the recording before \(action)."
        }
        return "Stop the recording before \(action)."
    }
}
