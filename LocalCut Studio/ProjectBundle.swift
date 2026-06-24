import Foundation
import CryptoKit
import UniformTypeIdentifiers
import LocalCutCore

// MARK: - Bundle content type

extension UTType {
    /// The `.lcbundle` project bundle: a directory the OS treats as one item.
    /// Conforming to `.package` is what makes Finder open it as a double-click
    /// target rather than browsing its insides. Full Launch Services adoption on
    /// a fresh install still needs an Info.plist `UTExportedTypeDeclarations`
    /// entry; the dynamic UTType here is enough for the in-app New/Open/Save
    /// path. See `Project Bundles` design § UTType for the follow-up.
    static let lcStudioProjectBundle = UTType(
        exportedAs: "com.localcutstudio.project-bundle",
        conformingTo: .package)
}

// MARK: - Fingerprints

/// SHA-256 fingerprinting of bundled assets. Streamed in fixed-size chunks so a
/// multi-GB master copy doesn't pull into RAM, and produced as a lowercase hex
/// string so `fingerprints.json` diffs cleanly.
nonisolated enum Fingerprint {
    /// Chunk size used for streaming. 256 KB is large enough that the syscall
    /// overhead is dwarfed by the read, and small enough not to flood RAM for
    /// the common case of "many small assets".
    private static let chunkSize = 256 * 1024

    /// Streams the file at `url` through SHA-256 and returns the lowercase hex
    /// digest. Throws if the file can't be opened.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hexString(from: hasher.finalize())
    }

    private static func hexString(from digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// On-disk fingerprint index keyed by bundle-relative path (`assets/<id>.<ext>`).
///
/// Serialised as a **top-level JSON object** (`{ "assets/<id>.<ext>": "<hex>" }`)
/// — the documented bundle-format shape — *not* nested under an `entries` field.
/// The custom Codable below flattens the single stored property and writes the
/// keys in sorted order itself, sidestepping the `singleValueContainer`-encoded
/// dictionary sorting gap. `encoded()` additionally sets `.sortedKeys` on the
/// encoder because macOS 26 Foundation's rewritten `JSONEncoder` does not
/// preserve keyed-container `container.encode(...)` call order without that
/// flag — see `encoded()` for why both guards are kept (belt and braces).
nonisolated struct FingerprintIndex: Codable, Equatable, Sendable {
    var entries: [String: String]

    init(entries: [String: String] = [:]) {
        self.entries = entries
    }

    /// Dynamic CodingKey for arbitrary string keys — lets the encoder emit
    /// keys in a deterministic order without going through a
    /// `singleValueContainer.encode([String: String])`, which doesn't
    /// always respect `.sortedKeys` on the outer encoder.
    private struct PathKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// Decodes a top-level `{ path: digest }` map.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: PathKey.self)
        var entries: [String: String] = [:]
        for key in container.allKeys {
            entries[key.stringValue] = try container.decode(String.self, forKey: key)
        }
        self.entries = entries
    }

    /// Encodes the entries map at the JSON root with sorted keys.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: PathKey.self)
        for (path, value) in entries.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: PathKey(path))
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Belt and braces: the manual `entries.keys.sorted()` loop in
        // `encode(to:)` above orders the keys we hand to the keyed container,
        // and `.sortedKeys` tells `JSONEncoder` to emit those keys in sorted
        // order on the way out. Swift Foundation's rewritten `JSONEncoder`
        // (macOS 26) does NOT preserve the order of `container.encode(...)`
        // calls for keyed containers without `.sortedKeys`, so the manual
        // sort alone can permute on re-encode; `.sortedKeys` alone would work
        // for `[String: String]` today but would silently regress if a
        // future path swapped to a non-string-keyed shape that the encoder
        // doesn't auto-sort. Keeping both makes byte-identity a stable
        // guarantee across Foundation revisions.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(FingerprintIndex.self, from: data)
    }
}

// MARK: - Bundle layout

/// The on-disk layout of a `.lcbundle` directory. The constants are gathered
/// here so the read and write paths can't drift on file names.
nonisolated enum ProjectBundleLayout {
    /// File extension for project bundles (e.g. `MyProject.lcbundle`).
    static let fileExtension = "lcbundle"
    /// Document JSON at the bundle root.
    static let projectJSON = "project.json"
    /// Fingerprint index at the bundle root.
    static let fingerprintsJSON = "fingerprints.json"
    /// Directory containing bundled media copies.
    static let assetsSubdirectory = "assets"

    /// Bundle-relative path for the given media UUID + source extension. Stable
    /// across renames in the bin so the on-disk layout doesn't churn on every
    /// bin rename.
    static func assetRelativePath(mediaID: UUID, sourceExtension: String) -> String {
        let ext = sourceExtension.isEmpty ? "" : ".\(sourceExtension)"
        return "\(assetsSubdirectory)/\(mediaID.uuidString)\(ext)"
    }

    /// Validates that `relative` stays under `assets/` inside the bundle: the
    /// path must start with `assets/`, contain no `..` components, and resolve
    /// to a single file directly under `assets/`. Returns `false` for anything
    /// a hand-edited or hostile `project.json` could use to escape the bundle.
    static func isSafeAssetRelativePath(_ relative: String) -> Bool {
        // Reject absolute paths outright.
        if relative.hasPrefix("/") { return false }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        // Expect exactly `assets/<filename>` — two non-empty components.
        guard components.count == 2,
              components[0] == Substring(assetsSubdirectory),
              !components[1].isEmpty else { return false }
        // No `.`/`..` traversal in the filename component.
        if components[1] == "." || components[1] == ".." { return false }
        // No nested slashes or backslashes that the split missed (defence in depth).
        if components[1].contains("/") || components[1].contains("\\") { return false }
        return true
    }
}

// MARK: - Read

/// The decoded contents of a `.lcbundle`. The fingerprint index is returned
/// alongside the document so the caller can re-fingerprint `assets/` and decide
/// whether to warn about external edits.
struct ProjectBundleContents {
    var document: ProjectDocument
    var fingerprints: FingerprintIndex
}

/// Raw bytes of a bundle's metadata files. Sendable across actor hops so the
/// IO portion of a read can run on a detached task while decode happens on the
/// owning actor.
nonisolated struct ProjectBundleData: Sendable {
    var projectJSON: Data
    var fingerprintsJSON: Data?
}

nonisolated enum ProjectBundle {

    /// Reads the raw metadata of a `.lcbundle`. Decode happens at the call site
    /// (on whichever actor owns the document model), so we can run this
    /// function from a detached IO task without needing `ProjectDocument` to
    /// be `Sendable`.
    static func readData(url bundleURL: URL) throws -> ProjectBundleData {
        let projectURL = bundleURL.appendingPathComponent(ProjectBundleLayout.projectJSON)
        let pdata = try Data(contentsOf: projectURL)
        let fingerprintsURL = bundleURL.appendingPathComponent(ProjectBundleLayout.fingerprintsJSON)
        let fdata = try? Data(contentsOf: fingerprintsURL)
        return ProjectBundleData(projectJSON: pdata, fingerprintsJSON: fdata)
    }

    /// Decodes raw bundle data into a document + fingerprint index. A missing
    /// or corrupt `fingerprints.json` is tolerated (the next save regenerates).
    ///
    /// `@MainActor`-isolated because `ProjectDocument.init(data:)` runs there
    /// under the module's default-isolation policy. The enum is otherwise
    /// `nonisolated` so the IO/write/hash methods can run on detached tasks.
    @MainActor
    static func decode(_ raw: ProjectBundleData) throws -> ProjectBundleContents {
        let document = try ProjectDocument(data: raw.projectJSON)
        let fingerprints = raw.fingerprintsJSON.flatMap { try? FingerprintIndex(data: $0) }
            ?? FingerprintIndex()
        return ProjectBundleContents(document: document, fingerprints: fingerprints)
    }

    /// Convenience: synchronous read + decode for callers on the main actor
    /// (tests, the synchronous close prompt).
    @MainActor
    static func read(url bundleURL: URL) throws -> ProjectBundleContents {
        try decode(readData(url: bundleURL))
    }

    /// Verifies the SHA-256 of every bundled asset against the stored index and
    /// returns the relative paths whose digest no longer matches. An entry in
    /// the index with no file on disk is also returned, so the caller can flag
    /// it as a missing asset.
    static func mismatches(in bundleURL: URL, against index: FingerprintIndex) -> [String] {
        var mismatched: [String] = []
        for (relative, expected) in index.entries {
            let url = bundleURL.appendingPathComponent(relative)
            guard let actual = try? Fingerprint.sha256(of: url) else {
                mismatched.append(relative)
                continue
            }
            if actual != expected { mismatched.append(relative) }
        }
        return mismatched
    }

    // MARK: - Write

    /// Describes a media item that should be copied into the bundle on save.
    /// The caller (EditorModel) supplies the source URL and the canonical
    /// in-bundle file name; ProjectBundle owns the copy and the fingerprint.
    struct BundledMedia: Sendable {
        let mediaID: UUID
        /// The source file on disk we are bundling from.
        let sourceURL: URL
        /// The bundle-relative path the copy lives at (`assets/<id>.<ext>`).
        let bundleRelativePath: String

        init(mediaID: UUID, sourceURL: URL, bundleRelativePath: String) {
            self.mediaID = mediaID
            self.sourceURL = sourceURL
            self.bundleRelativePath = bundleRelativePath
        }
    }

    /// Errors raised by `ProjectBundle.write`.
    enum WriteError: Error, LocalizedError {
        case unsafeRelativePath(String)

        var errorDescription: String? {
            switch self {
            case .unsafeRelativePath(let path):
                return "Bundle reference \"\(path)\" escapes the bundle directory."
            }
        }
    }

    /// Writes a `.lcbundle` to `bundleURL`. Steps:
    ///
    /// 1. Create `bundleURL` and `assets/` if missing.
    /// 2. For each `bundledMedia` entry:
    ///    - Skip if `sourceURL` already IS the destination (the project was
    ///      reopened from this bundle — the only existing copy is the one we'd
    ///      otherwise delete-and-recopy from itself; this is the P0 fix).
    ///    - Skip if the source's current SHA matches the stored fingerprint
    ///      AND the destination's current SHA also matches (the bundled copy
    ///      hasn't been edited externally either) — the fast path.
    ///    - If the source is unreachable but the destination still matches the
    ///      stored fingerprint, treat the cached bundle copy as authoritative
    ///      (covers the "user unplugged the source drive" case).
    ///    - Otherwise: copy to a temp neighbour file first, then move into
    ///      place — so a mid-flight failure can't leave the destination empty.
    /// 3. Compute fresh fingerprints for every file under `assets/`.
    /// 4. Stage `fingerprints.json` and `project.json`, then promote them
    ///    after both staged writes have succeeded.
    ///
    /// `projectJSON` is supplied pre-encoded so the caller can produce it on
    /// the main actor (where the document model lives) and hand only Sendable
    /// values across the actor hop.
    ///
    /// Returns the regenerated `FingerprintIndex` so the caller can stash it on
    /// the editor for the next save's fast path.
    @discardableResult
    static func write(projectJSON: Data,
                      to bundleURL: URL,
                      bundledMedia: [BundledMedia],
                      previousFingerprints: FingerprintIndex) throws -> FingerprintIndex {
        // Path-safety pass first, so a hostile `project.json` can't make us
        // touch anything outside `assets/` before we even open a file handle.
        for media in bundledMedia where !ProjectBundleLayout.isSafeAssetRelativePath(media.bundleRelativePath) {
            throw WriteError.unsafeRelativePath(media.bundleRelativePath)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let assetsURL = bundleURL.appendingPathComponent(ProjectBundleLayout.assetsSubdirectory)
        try fm.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        // Collect digests during the copy/skip loop so we don't re-hash
        // every file a second time at the end.
        var index = FingerprintIndex()
        for media in bundledMedia {
            let destination = bundleURL.appendingPathComponent(media.bundleRelativePath)

            // P0: source IS destination. Reopening a bundle leaves the runtime
            // MediaItem pointed at the bundled copy; the next save would
            // otherwise delete-and-recopy from a file we just removed. The only
            // existing copy of the user's media would be lost.
            if media.sourceURL.standardizedFileURL == destination.standardizedFileURL {
                if let digest = try? Fingerprint.sha256(of: destination) {
                    index.entries[media.bundleRelativePath] = digest
                }
                continue
            }

            let storedDigest = previousFingerprints.entries[media.bundleRelativePath]
            let sourceDigest = try? Fingerprint.sha256(of: media.sourceURL)
            let destinationExists = fm.fileExists(atPath: destination.path)
            let destinationDigest = destinationExists
                ? try? Fingerprint.sha256(of: destination)
                : nil

            // Fast path: source AND destination both still match what we
            // recorded last save. Recomputing both digests prevents a silent
            // accept of an externally-edited bundled copy.
            if let storedDigest,
               sourceDigest == storedDigest,
               destinationDigest == storedDigest {
                index.entries[media.bundleRelativePath] = storedDigest
                continue
            }

            // Source unreachable (e.g. external drive unplugged), but the
            // destination still matches the stored fingerprint — keep the
            // bundled copy and move on. Without this, an unplugged source
            // would crash the entire save.
            if sourceDigest == nil,
               let storedDigest,
               destinationDigest == storedDigest {
                index.entries[media.bundleRelativePath] = storedDigest
                continue
            }

            // Copy via a temp neighbour file, then atomically replace the
            // destination — a mid-flight crash leaves the previous destination
            // (if any) intact rather than partially-written or empty.
            let temp = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: media.sourceURL, to: temp)
            if destinationExists {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }

            // The copied file's digest is identical to the source digest we
            // already computed above.
            if let sourceDigest {
                index.entries[media.bundleRelativePath] = sourceDigest
            } else if let digest = try? Fingerprint.sha256(of: destination) {
                index.entries[media.bundleRelativePath] = digest
            }
        }

        try writeMetadata(projectJSON: projectJSON, fingerprints: index, to: bundleURL)
        return index
    }

    private static func writeMetadata(projectJSON: Data,
                                      fingerprints: FingerprintIndex,
                                      to bundleURL: URL) throws {
        let fm = FileManager.default
        let token = UUID().uuidString
        let stagedFingerprints = bundleURL
            .appendingPathComponent(".\(ProjectBundleLayout.fingerprintsJSON).staged-\(token)")
        let stagedProject = bundleURL
            .appendingPathComponent(".\(ProjectBundleLayout.projectJSON).staged-\(token)")
        defer {
            try? fm.removeItem(at: stagedFingerprints)
            try? fm.removeItem(at: stagedProject)
        }

        try fingerprints.encoded().write(to: stagedFingerprints, options: .atomic)
        try projectJSON.write(to: stagedProject, options: .atomic)

        try promoteMetadataFile(stagedFingerprints,
                                to: bundleURL.appendingPathComponent(ProjectBundleLayout.fingerprintsJSON))
        try promoteMetadataFile(stagedProject,
                                to: bundleURL.appendingPathComponent(ProjectBundleLayout.projectJSON))
    }

    private static func promoteMetadataFile(_ staged: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }

    // MARK: - Detection

    /// Whether the URL points to a `.lcbundle` directory. Used by the open path
    /// to dispatch between bundle and single-file loads.
    ///
    /// The `project.json` fallback after the extension check is intentional: the
    /// open panel already filters to `.lcbundle`/`.lcstudio`, so the fallback
    /// only fires for edge cases where a bundle arrives without the canonical
    /// extension (e.g. a file-sync service that strips extensions, or a user
    /// who renamed the directory). A random directory opened by mistake will
    /// fail the `project.json` existence check and fall through to the
    /// single-file decode path, which returns its own error.
    static func isBundle(url: URL) -> Bool {
        // Extension first — the cheap check — then a directory test in case the
        // user (or a synced volume) saved a bundle without the canonical suffix.
        if url.pathExtension == ProjectBundleLayout.fileExtension { return true }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else { return false }
        // Look for a `project.json` at the root to disambiguate from a random
        // directory the user opened by mistake.
        let project = url.appendingPathComponent(ProjectBundleLayout.projectJSON)
        return FileManager.default.fileExists(atPath: project.path)
    }
}
