import Foundation
import AVFoundation
import LocalCutCore

/// Focused state container for document lifecycle and persistence.
/// Extracted from EditorModel to improve cohesion and testability.
@Observable
@MainActor
final class DocumentState {
    /// The file backing the current project, or `nil` for an unsaved one.
    var documentURL: URL?
    /// Whether the project has unsaved changes (drives the window's edited dot).
    var isDirty = false
    /// True while a window-close Save choice is already writing asynchronously.
    @ObservationIgnored var closeSaveInProgress = false
    /// Media references whose files couldn't be resolved on open; awaiting relink.
    var unresolvedMedia: [MediaRef] = []
    /// SHA-256 of every bundled asset as of the last successful bundle read or
    /// write. Used by the next bundle save's fast path to skip re-copying media
    /// whose source hasn't changed since the previous save.
    @ObservationIgnored var lastBundleFingerprints = FingerprintIndex()

    /// Security-scoped resources retained for the session, stopped on teardown.
    /// Holds **per-file** bookmark-resolved URLs only — never the outer
    /// `.lcbundle` directory URL.
    @ObservationIgnored nonisolated(unsafe) var accessedURLs: Set<URL> = []

    /// Security-scoped access on the outer `.lcbundle` directory, when the
    /// current document is a bundle.
    @ObservationIgnored nonisolated(unsafe) var bundleAccessURL: URL?

    /// Bumped on every session swap (New/Open). Async import/relink capture it
    /// and bail if it changes across their awaits.
    @ObservationIgnored var sessionGeneration = 0

    /// Monotonically increases on every mutation; lets an async save tell whether
    /// the project changed between snapshotting its data and finishing the write.
    @ObservationIgnored var mutationRevision = 0

    /// Marks the document as dirty and bumps the mutation revision.
    func markDirty() {
        isDirty = true
        mutationRevision &+= 1
    }

    /// Records a successful security-scoped start, keeping exactly one
    /// outstanding access per URL.
    func retainAccess(_ url: URL, didStart: Bool) {
        guard didStart else { return }
        accessedURLs.insert(url)
    }

    /// Releases all security-scoped resources.
    func releaseAllAccess() {
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
        bundleAccessURL?.stopAccessingSecurityScopedResource()
        bundleAccessURL = nil
    }
}
