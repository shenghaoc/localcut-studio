import Foundation
import AppKit
import UniformTypeIdentifiers

/// AppKit panel/prompt glue for the document menu commands and the close flow.
/// Kept apart from the pure persistence logic so the model's save/open/undo code
/// stays free of panel presentation.
extension EditorModel {

    // MARK: - Menu actions

    /// File ▸ New — offers to save first, then resets to an empty project.
    func requestNew() {
        Task {
            guard await confirmSaveIfNeeded() else { return }
            newDocument()
        }
    }

    /// File ▸ Open — offers to save first, then presents an open panel.
    func requestOpen() {
        Task {
            guard await confirmSaveIfNeeded() else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.lcStudioProject]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            await open(url: url)
        }
    }

    /// File ▸ Save — writes to the current URL, or prompts for one if unsaved.
    func requestSave() {
        Task {
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
            if let url = runSavePanel() { await saveAs(url: url) }
        }
    }

    // MARK: - Panels & prompts

    /// Presents a save panel for a `.lcstudio` document; returns the chosen URL.
    func runSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.lcStudioProject]
        panel.nameFieldStringValue = "\(project.name).\(ProjectDocument.fileExtension)"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// If there are unsaved changes, asks whether to save. Returns `true` if the
    /// caller may proceed (saved or discarded) and `false` if the user cancelled.
    func confirmSaveIfNeeded() async -> Bool {
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
    func confirmCloseSynchronously() -> Bool {
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
            return writeSynchronously(to: url)
        case .alertSecondButtonReturn:       // Don't Save
            return true
        default:                             // Cancel
            return false
        }
    }
}
