import Foundation
import LocalCutCore

/// How a LocalCut project is stored on the local filesystem.
///
/// Persist this alongside `documentURL` after a successful open or Save As so
/// later Save routing never re-sniffs the path with loose heuristics.
nonisolated enum ProjectStorageKind: Equatable, Sendable {
    /// A single regular file with the `.lcstudio` extension.
    case singleFile
    /// A directory package (canonical `.lcbundle` or a validated extensionless
    /// LocalCut bundle directory).
    case bundle
}

/// Result of classifying a user-selected local filesystem URL as a LocalCut
/// project location. Produced by `ProjectLocationInspector` and consumed by
/// Open, Open Recent, and open-panel validation.
nonisolated struct ProjectOpenDescriptor: Equatable, Sendable {
    /// Local filesystem URL selected by the user (file or directory package).
    let url: URL
    let storageKind: ProjectStorageKind
}

/// Single classification path for Open / Open Recent / panel validation.
///
/// A directory is accepted only when its `project.json` decodes as a supported
/// LocalCut document **and** advertises a supported `bundleFormat`. Existence
/// of a file named `project.json` is never sufficient on its own.
nonisolated enum ProjectLocationInspector {
    /// Supported `bundleFormat` values that may be opened as a LocalCut package.
    static let supportedBundleFormats: Set<String> = [
        ProjectDocument.currentBundleFormat
    ]

    /// Classification runs synchronously for open-panel validation. Bound the
    /// metadata read so a renamed media file cannot make that path allocate an
    /// arbitrarily large buffer on the main actor.
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

    /// Convenience used by open-panel validation and callers that only need a
    /// yes/no answer. Equivalent to `inspect(url) != nil`.
    static func isSupportedProjectLocation(_ url: URL) -> Bool {
        inspect(url) != nil
    }

    /// Whether `url` is a validated LocalCut bundle directory.
    ///
    /// This performs full metadata validation — not a loose content sniff.
    /// Prefer the stored `projectStorageKind` on `EditorModel` for save routing
    /// after a successful open; use this for one-shot classification of an
    /// arbitrary local filesystem URL.
    static func isValidatedBundle(_ url: URL) -> Bool {
        inspect(url)?.storageKind == .bundle
    }

    /// Storage kind implied by a Save As destination filename extension.
    /// Does not inspect disk contents. Content-type selection in the save
    /// panel is reflected in the returned URL's extension via the panel
    /// type delegate.
    static func storageKindForSaveDestination(url: URL) -> ProjectStorageKind? {
        switch url.pathExtension {
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
        guard url.pathExtension == ProjectDocument.fileExtension else {
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
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumMetadataSize else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}
