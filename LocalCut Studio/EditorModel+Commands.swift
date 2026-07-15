import Foundation
import AppKit
import UniformTypeIdentifiers
import LocalCutCore

enum EditorCommandOutcome: Equatable, Sendable {
    case completed
    case actionCancelled
    case failed
    case panelCancelled
}

/// Captures AppKit panels behind a Sendable handle so cancellation can hop
/// back to the main actor without sending the panel across actors directly.
/// `@unchecked Sendable` is required because `NSSavePanel` is `@MainActor`-
/// isolated and not `Sendable`; the handle is only ever created and consumed
/// on `@MainActor`, so the runtime invariant holds.
@MainActor
private final class PanelCancellationHandle: @unchecked Sendable {
    let panel: NSSavePanel

    init(_ panel: NSSavePanel) {
        self.panel = panel
    }

    func cancel() {
        panel.cancel(nil)
    }
}

/// Centralizes the project-open panel policy so package selection remains
/// regression-testable without coupling a test to an asynchronous menu action.
@MainActor
enum ProjectOpenPanelConfiguration {
    static func apply(to panel: NSOpenPanel) {
        // `.lcbundle` has an in-process filename-backed UTType rather than a
        // Finder-registered document type. NSOpenPanel cannot match that
        // runtime type for a directory, so leave the type filter unrestricted
        // and validate through the panel delegate below. This keeps real
        // bundles selectable without accepting an unrelated path as a project.
        panel.allowsMultipleSelection = false
        // LocalCut bundles are directories on disk, so accept directory
        // candidates and validate their canonical project metadata at the
        // panel boundary.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // Let AppKit present Launch Services-recognized packages as documents.
        // An unregistered runtime `.lcbundle` may still appear as a folder, so
        // the validator below remains the authority before loading it.
        panel.treatsFilePackagesAsDirectories = false
    }

    static func isSupportedProjectURL(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            // Use the same canonical metadata predicate as the production
            // bundle loader so a synced or renamed bundle keeps its package
            // save path after it is opened.
            let projectJSON = url.appendingPathComponent(ProjectBundleLayout.projectJSON)
            return FileManager.default.fileExists(atPath: projectJSON.path)
        }
        return url.pathExtension == ProjectDocument.fileExtension
    }
}

/// Centralizes the project-save panel policy so the default document shape is
/// explicit even when the panel also offers the legacy flat-file type.
@MainActor
enum ProjectSavePanelConfiguration {
    static func apply(to panel: NSSavePanel, suggestedName: String) {
        panel.allowedContentTypes = [.lcStudioProjectBundle, .lcStudioProject]
        // `NSSavePanel` otherwise chooses its current type independently of
        // the array order when the suggested name already has an extension,
        // which can produce `Project.lcbundle.lcstudio`. Select the package
        // type deliberately so a new save starts as the portable bundle.
        panel.currentContentType = .lcStudioProjectBundle
        panel.showsContentTypes = true
        panel.nameFieldStringValue = "\(suggestedName).\(ProjectBundleLayout.fileExtension)"
        panel.canCreateDirectories = true
    }

    static func filename(_ currentName: String, for contentType: UTType) -> String {
        let baseName = URL(filePath: currentName).deletingPathExtension().lastPathComponent
        let filenameExtension = contentType.preferredFilenameExtension ?? ProjectBundleLayout.fileExtension
        return "\(baseName).\(filenameExtension)"
    }
}

/// `NSSavePanel` owns the type popup; this narrow delegate keeps the filename
/// extension aligned with the user's selected project representation.
@MainActor
private final class ProjectSavePanelTypeDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, didSelect type: UTType?) {
        guard let panel = sender as? NSSavePanel, let type else { return }
        panel.nameFieldStringValue = ProjectSavePanelConfiguration.filename(
            panel.nameFieldStringValue,
            for: type)
    }

    func panel(_ sender: Any, displayNameFor type: UTType) -> String? {
        switch type {
        case .lcStudioProjectBundle:
            "LocalCut Bundle (.lcbundle)"
        case .lcStudioProject:
            "LocalCut Project (.lcstudio)"
        default:
            nil
        }
    }
}

/// Keeps invalid folders from dismissing the project-open panel. The panel
/// holds its delegate weakly, so `requestOpen()` captures an instance through
/// the asynchronous completion handler for the full presentation lifetime.
@MainActor
private final class ProjectOpenPanelValidator: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard ProjectOpenPanelConfiguration.isSupportedProjectURL(url) else {
            throw NSError(
                domain: "LocalCutStudio.ProjectOpen",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose a LocalCut project (.lcstudio or .lcbundle)."]
            )
        }
    }
}

/// AppKit panel/prompt glue for the document menu commands and the close flow.
/// Kept apart from the pure persistence logic so the model's save/open/undo code
/// stays free of panel presentation.
extension EditorModel {

    // MARK: - Menu actions

    /// File ▸ New — offers to save first, then resets to an empty project.
    func requestNew() {
        Task { [weak self] in
            guard let self else { return }
            _ = await performNewProjectCommand()
        }
    }

    /// File ▸ Open — offers to save first, then presents an open panel that
    /// accepts both `.lcstudio` (legacy single-file) and `.lcbundle` (package).
    func requestOpen() {
        Task { [weak self] in
            guard let self else { return }
            _ = await performOpenProjectCommand()
        }
    }

    func requestOpenRecent(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
            _ = await performImportMediaCommand()
        }
    }

    /// File ▸ Export… — presents the same save panel the toolbar Export button
    /// uses and queues a render with the default preset, so the app's primary
    /// output action has a menu home and a ⇧⌘E shortcut.
    func requestExport() {
        Task { [weak self] in
            guard let self else { return }
            _ = await performExportProjectCommand()
        }
    }

    @discardableResult
    func performNewProjectCommand() async -> EditorCommandOutcome {
        await performNewProjectCommand(
            confirmSave: { [self] in
                await confirmSaveIfNeeded()
            },
            resetDocument: { [self] in
                newDocument()
            })
    }

    @discardableResult
    func performNewProjectCommand(
        confirmSave: @escaping @MainActor () async -> Bool,
        resetDocument: @escaping @MainActor () -> Void
    ) async -> EditorCommandOutcome {
        guard !blockDocumentCommandWhileRecording() else { return .actionCancelled }
        let previousStatus = statusMessage
        guard await confirmSave() else {
            if statusMessage == previousStatus {
                statusMessage = String(localized: "Action cancelled.")
            }
            return .actionCancelled
        }
        guard !Task.isCancelled else {
            if statusMessage == previousStatus {
                statusMessage = String(localized: "Action cancelled.")
            }
            return .actionCancelled
        }
        resetDocument()
        return .completed
    }

    @discardableResult
    func performOpenProjectCommand() async -> EditorCommandOutcome {
        await performOpenProjectCommand(
            confirmSave: { [self] in
                await confirmSaveIfNeeded()
            },
            presentPanel: { [self] in
                await presentProjectOpenPanel()
            },
            openProject: { [self] url in
                await open(url: url)
            })
    }

    /// Injectable command seam keeps the recording guard and URL validation
    /// deterministic without coupling lifecycle tests to a live open panel.
    @discardableResult
    func performOpenProjectCommand(
        confirmSave: @escaping @MainActor () async -> Bool,
        presentPanel: @escaping @MainActor () async -> (NSApplication.ModalResponse, URL?),
        openProject: @escaping @MainActor (URL) async -> Void
    ) async -> EditorCommandOutcome {
        guard !blockDocumentCommandWhileRecording() else { return .actionCancelled }
        guard await confirmSave() else { return .actionCancelled }
        let (response, url) = await presentPanel()
        guard response == .OK, let url else { return .panelCancelled }
        guard ProjectOpenPanelConfiguration.isSupportedProjectURL(url) else {
            statusMessage = "Choose a LocalCut project (.lcstudio or .lcbundle)."
            return .failed
        }
        await openProject(url)
        return .completed
    }

    @discardableResult
    func performImportMediaCommand() async -> EditorCommandOutcome {
        await performImportMediaCommand(
            presentPanel: { [self] in
                await presentImportMediaPanel()
            },
            importMediaAction: { [self] urls in
                await importMedia(urls: urls, wantsBundling: copyImportsIntoBundle)
            })
    }

    @discardableResult
    func performImportMediaCommand(
        presentPanel: @escaping @MainActor () async -> (NSApplication.ModalResponse, [URL]),
        importMediaAction: @escaping @MainActor ([URL]) async -> EditorCommandOutcome
    ) async -> EditorCommandOutcome {
        let (response, urls) = await presentPanel()
        guard response == .OK, !urls.isEmpty else {
            return .panelCancelled
        }
        return await importMediaAction(urls)
    }

    private func presentImportMediaPanel() async -> (NSApplication.ModalResponse, [URL]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent,
                                     .audio, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        let cancellationHandle = PanelCancellationHandle(panel)
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                MainActor.assumeIsolated {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: NSApplication.ModalResponse.cancel)
                        return
                    }
                    cancellationHandle.panel.begin { response in
                        continuation.resume(returning: response)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                cancellationHandle.cancel()
            }
        }
        return (response, panel.urls)
    }

    private func presentProjectOpenPanel() async -> (NSApplication.ModalResponse, URL?) {
        let panel = NSOpenPanel()
        ProjectOpenPanelConfiguration.apply(to: panel)
        let validator = ProjectOpenPanelValidator()
        panel.delegate = validator
        let response = await withCheckedContinuation { continuation in
            panel.begin { [validator] response in
                _ = validator
                continuation.resume(returning: response)
            }
        }
        return (response, panel.url)
    }

    @discardableResult
    func performExportProjectCommand() async -> EditorCommandOutcome {
        await performExportProjectCommand(
            presentPanel: { [self] in
                await presentExportProjectPanel()
            },
            exportProject: { [self] url in
                await export(to: url)
            })
    }

    @discardableResult
    func performExportProjectCommand(
        presentPanel: @escaping @MainActor () async -> (NSApplication.ModalResponse, URL?),
        exportProject: @escaping @MainActor (URL) async -> EditorCommandOutcome
    ) async -> EditorCommandOutcome {
        guard totalDuration > 0 else {
            statusMessage = String(localized: "Add media to the timeline before exporting.")
            return .actionCancelled
        }
        guard resolveChapterMarkersBeforeExport() else { return .actionCancelled }
        let (response, url) = await presentPanel()
        guard response == .OK, let url else {
            return .panelCancelled
        }
        return await exportProject(url)
    }

    private func presentExportProjectPanel() async -> (NSApplication.ModalResponse, URL?) {
        let preset = BuiltInExportPresets.defaultPreset
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: preset.defaultFilenameExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(project.name).\(preset.defaultFilenameExtension)"
        panel.canCreateDirectories = true
        let cancellationHandle = PanelCancellationHandle(panel)
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                MainActor.assumeIsolated {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: NSApplication.ModalResponse.cancel)
                        return
                    }
                    cancellationHandle.panel.begin { response in
                        continuation.resume(returning: response)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                cancellationHandle.cancel()
            }
        }
        return (response, panel.url)
    }

    /// Creates an in-memory OTIO document for the focused window's SwiftUI
    /// file exporter. Serialization stays in the existing interchange layer;
    /// only destination presentation moves out of the AppKit save panel.
    func makeOtioExportRequest() -> InterchangeExportRequest? {
        guard totalDuration > 0 else { return nil }
        let document = documentController.makeDocumentForSave(forBundle: false, model: self)
        // Snapshot media names before the Sendable closure.
        let mediaNames: [UUID: String] = Dictionary(
            project.mediaItems.map { ($0.id, $0.url.lastPathComponent) },
            uniquingKeysWith: { first, _ in first })
        let options = OtioSerializationOptions(
            bundleMode: false,
            resolveTargetUrl: { mediaID in
                mediaNames[mediaID] ?? mediaID.uuidString
            },
            isMediaResolved: { mediaID in
                mediaNames[mediaID] != nil
            })
        let (json, warnings) = serializeTimelineToOtio(document, options: options)
        if warnings.contains(where: { $0.kind == .serializationFailure }) {
            statusMessage = "OTIO export failed: serialization error."
            return nil
        }
        return InterchangeExportRequest(
            document: InterchangeExportDocument(contents: json),
            contentType: .localCutOtioExport,
            // SwiftUI's file exporter derives and appends the content type's
            // extension. Passing an already suffixed name produces `.otio.otio`.
            defaultFilename: project.name,
            warningSummary: warningSummary(warnings))
    }

    /// Creates an in-memory CMX3600 EDL document for the focused window's
    /// SwiftUI file exporter after the scene chooses a video track.
    func makeEdlExportRequest(trackIndex: Int) -> InterchangeExportRequest? {
        guard totalDuration > 0 else { return nil }
        guard project.videoTracks.indices.contains(trackIndex) else {
            statusMessage = "No video tracks to export."
            return nil
        }
        let document = documentController.makeDocumentForSave(forBundle: false, model: self)
        let options = EdlSerializationOptions(
            title: project.name,
            videoTrackIndex: trackIndex)
        let (edl, warnings) = serializeTimelineToEdl(document, options: options)
        if warnings.contains(where: { $0.kind == .serializationFailure }) {
            statusMessage = "EDL export failed: serialization error."
            return nil
        }
        return InterchangeExportRequest(
            document: InterchangeExportDocument(contents: edl),
            contentType: .localCutEdlExport,
            defaultFilename: project.name,
            warningSummary: warningSummary(warnings))
    }

    private func warningSummary(_ warnings: [InterchangeWarning]) -> String? {
        guard !warnings.isEmpty else { return nil }
        return warnings.prefix(3).map(\.description).joined(separator: "; ")
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
        alert.messageText = "Chapter markers need attention before export"
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
            statusMessage = "Export cancelled. Fix the chapter marker issues above, then try again."
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
        alert.messageText = "Chapter markers need attention before export"
        alert.informativeText = chapterIssueSummary(issues)
        alert.addButton(withTitle: "OK")
        alert.runModal()
        statusMessage = "\(issues.count) chapter marker issue(s) to fix before export."
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
        Task { [weak self] in
            guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
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
        let typeDelegate = ProjectSavePanelTypeDelegate()
        panel.delegate = typeDelegate
        ProjectSavePanelConfiguration.apply(to: panel, suggestedName: project.name)
        let response = panel.runModal()
        _ = typeDelegate // `NSSavePanel.delegate` is weak.
        return response == .OK ? panel.url : nil
    }

    /// File ▸ Convert to Bundle… — writes a fresh `.lcbundle` alongside the
    /// existing `.lcstudio`, leaving the original untouched (R4.2 / R4.3).
    func requestConvertToBundle() {
        guard canConvertToBundle else { return }
        Task { [weak self] in
            guard let self else { return }
            guard !blockDocumentCommandDuringCloseSave() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.lcStudioProjectBundle]
            panel.currentContentType = .lcStudioProjectBundle
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
        confirmClose(window: window, onSaveSucceeded: {})
    }

    /// Starts an async save when needed. The window bridge supplies the
    /// completion handoff that replays the close after a successful save.
    func confirmClose(
        window _: NSWindow,
        onSaveSucceeded: @escaping @MainActor () -> Void
    ) -> Bool {
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.documentURL == nil {
                    await self.saveAs(url: url)
                } else {
                    await self.save()
                }
                let shouldClose = !self.isDirty
                self.closeSaveInProgress = false
                if shouldClose, !self.hasActiveRecordingLifecycle {
                    onSaveSucceeded()
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
