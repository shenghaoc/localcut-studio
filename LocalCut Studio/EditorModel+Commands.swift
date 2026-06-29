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
        guard !isRecording, !isPaused, !isStartingRecording, !isStoppingRecording else {
            statusMessage = isStartingRecording
                ? "Wait for the recording to start before closing the window."
                : isStoppingRecording
                    ? "Finish stopping the recording before closing the window."
                    : isPaused
                        ? "Resume and stop the recording before closing the window."
                        : "Stop the recording before closing the window."
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
        guard isRecording || isPaused || isStartingRecording || isStoppingRecording else { return false }
        statusMessage = isStartingRecording
            ? "Wait for the recording to start before switching projects."
            : isStoppingRecording
                ? "Finish stopping the recording before switching projects."
                : isPaused
                    ? "Resume and stop the recording before switching projects."
                    : "Stop the recording before switching projects."
        return true
    }
}
