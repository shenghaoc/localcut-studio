import Foundation
import LocalCutCore

/// How a LocalCut project is stored on the local filesystem.
///
/// Stored inside `ProjectSessionLocation` after a successful open or Save As so
/// later Save routing never re-sniffs the path with loose heuristics.
nonisolated enum ProjectStorageKind: Equatable, Sendable {
    /// A single regular file with the `.lcstudio` extension.
    case singleFile
    /// A directory package (canonical `.lcbundle` or a validated extensionless
    /// LocalCut bundle directory).
    case bundle
}

/// A document session is either unsaved or has one inseparable URL/storage
/// pairing. Modeling the pair as one value prevents Save and queued-export
/// routing from observing a URL without its representation (or vice versa).
nonisolated enum ProjectSessionLocation: Equatable, Sendable {
    case unsaved
    case saved(url: URL, storageKind: ProjectStorageKind)

    var url: URL? {
        guard case .saved(let url, _) = self else { return nil }
        return url
    }

    var storageKind: ProjectStorageKind? {
        guard case .saved(_, let storageKind) = self else { return nil }
        return storageKind
    }
}

/// Result of classifying a user-selected local filesystem URL as a LocalCut
/// project location. Produced by `ProjectLocationInspector` and consumed by
/// Open and Open Recent after their cheap panel/menu candidate checks.
nonisolated struct ProjectOpenDescriptor: Equatable, Sendable {
    /// Local filesystem URL selected by the user (file or directory package).
    let url: URL
    let storageKind: ProjectStorageKind
}

/// Full classification path used by Open after the panel returns.
///
/// A directory is accepted only when its `project.json` decodes as a supported
/// LocalCut document **and** advertises a supported `bundleFormat`. Existence
/// of a file named `project.json` is never sufficient on its own.
nonisolated enum ProjectLocationInspector {
    /// Supported `bundleFormat` values that may be opened as a LocalCut package.
    static let supportedBundleFormats: Set<String> = [
        ProjectDocument.currentBundleFormat
    ]

    /// Bound every metadata read before decoding so a renamed media file cannot
    /// allocate an arbitrarily large buffer. Full inspection runs off the main
    /// actor; the open panel uses `isOpenPanelCandidate(_:)` below.
    static let maximumMetadataSize = 10 * 1024 * 1024

    /// Classifies `url` as a LocalCut project location, or returns `nil` when
    /// the path is not a supported single-file project or validated bundle.
    static func inspect(_ url: URL) -> ProjectOpenDescriptor? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return inspectBundleDirectory(url)
        }
        return inspectSingleFile(url)
    }

    /// Cheap open-panel boundary: validate only filesystem shape, extension,
    /// and the same metadata-size ceiling used by the detached full inspector.
    /// JSON decoding is intentionally deferred to `inspect(_:)` during Open.
    static func isOpenPanelCandidate(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            return hasBoundedRegularMetadata(
                at: url.appendingPathComponent(ProjectBundleLayout.projectJSON))
        }
        guard url.pathExtension.lowercased() == ProjectDocument.fileExtension else {
            return false
        }
        return hasBoundedRegularMetadata(at: url)
    }

    /// Identifies a URL that can be displayed in Open Recent without touching
    /// the filesystem. The recent-document controller is populated only after
    /// a successful Open or Save, and `DocumentController.open` revalidates a
    /// selected candidate before loading it. Extensionless URLs are retained
    /// for validated synced bundle projects.
    static func isRecentProjectCandidate(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case ProjectDocument.fileExtension, ProjectBundleLayout.fileExtension, "":
            true
        default:
            false
        }
    }

    /// Whether `url` is a validated LocalCut bundle directory.
    ///
    /// This performs full metadata validation — not a loose content sniff.
    /// Prefer `EditorModel.projectSessionLocation` for save routing after a
    /// successful open; use this for one-shot classification of an arbitrary
    /// local filesystem URL.
    static func isValidatedBundle(_ url: URL) -> Bool {
        inspect(url)?.storageKind == .bundle
    }

    /// Storage kind implied by a Save As destination filename extension.
    /// Does not inspect disk contents. Content-type selection in the save
    /// panel is reflected in the returned URL's extension via the panel
    /// type delegate.
    static func storageKindForSaveDestination(url: URL) -> ProjectStorageKind? {
        switch url.pathExtension.lowercased() {
        case ProjectBundleLayout.fileExtension:
            return .bundle
        case ProjectDocument.fileExtension:
            return .singleFile
        default:
            return nil
        }
    }

    // MARK: - Private

    private static func inspectSingleFile(_ url: URL) -> ProjectOpenDescriptor? {
        // A regular file with an `.lcbundle` suffix is not a package.
        guard url.pathExtension.lowercased() == ProjectDocument.fileExtension else {
            return nil
        }
        guard let data = readBoundedMetadata(at: url),
              (try? ProjectDocument(data: data)) != nil else {
            return nil
        }
        return ProjectOpenDescriptor(url: url, storageKind: .singleFile)
    }

    private static func inspectBundleDirectory(_ url: URL) -> ProjectOpenDescriptor? {
        let projectJSON = url.appendingPathComponent(ProjectBundleLayout.projectJSON)
        guard FileManager.default.isReadableFile(atPath: projectJSON.path),
              let data = readBoundedMetadata(at: projectJSON),
              let document = try? ProjectDocument(data: data),
              let format = document.bundleFormat,
              supportedBundleFormats.contains(format) else {
            return nil
        }
        return ProjectOpenDescriptor(url: url, storageKind: .bundle)
    }

    private static func readBoundedMetadata(at url: URL) -> Data? {
        guard hasBoundedRegularMetadata(at: url) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func hasBoundedRegularMetadata(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumMetadataSize else {
            return false
        }
        return true
    }
}
