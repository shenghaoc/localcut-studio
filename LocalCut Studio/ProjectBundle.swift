import Foundation
import CryptoKit
import UniformTypeIdentifiers

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
/// Serialised with sorted keys so a re-save with no fingerprint changes produces
/// byte-identical JSON.
nonisolated struct FingerprintIndex: Codable, Equatable, Sendable {
    var entries: [String: String]

    init(entries: [String: String] = [:]) {
        self.entries = entries
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
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
    static func decode(_ raw: ProjectBundleData) throws -> ProjectBundleContents {
        let document = try ProjectDocument(data: raw.projectJSON)
        let fingerprints = raw.fingerprintsJSON.flatMap { try? FingerprintIndex(data: $0) }
            ?? FingerprintIndex()
        return ProjectBundleContents(document: document, fingerprints: fingerprints)
    }

    /// Convenience: synchronous read + decode for callers that don't need to
    /// hop actors (tests, the synchronous close prompt).
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

    /// Writes a `.lcbundle` to `bundleURL`. Steps:
    ///
    /// 1. Create `bundleURL` and `assets/` if missing.
    /// 2. For each `bundledMedia` entry: if the previously-recorded fingerprint
    ///    matches the source's current SHA-256, skip the copy (fast path);
    ///    otherwise copy the file (APFS clones on the same volume).
    /// 3. Compute fresh fingerprints for every file under `assets/`.
    /// 4. Write `fingerprints.json` and `project.json` atomically.
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
        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let assetsURL = bundleURL.appendingPathComponent(ProjectBundleLayout.assetsSubdirectory)
        try fm.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        for media in bundledMedia {
            let destination = bundleURL.appendingPathComponent(media.bundleRelativePath)
            // Fast path: the source's current SHA matches the previously-stored
            // fingerprint for this destination AND the destination already
            // exists. We can leave the copy in place untouched.
            let storedDigest = previousFingerprints.entries[media.bundleRelativePath]
            if let storedDigest,
               fm.fileExists(atPath: destination.path),
               let sourceDigest = try? Fingerprint.sha256(of: media.sourceURL),
               sourceDigest == storedDigest {
                continue
            }
            // Replace any stale copy.
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            // copyItem on APFS already uses a clonefile-style fast path when
            // source and destination are on the same volume.
            try fm.copyItem(at: media.sourceURL, to: destination)
        }

        // Re-fingerprint the assets directory from scratch — anything left
        // behind by a previous run (e.g. an asset whose media item was deleted)
        // shouldn't appear in the index. The caller can prune orphaned files in
        // a future tidy-up pass; for now we leave them on disk but unindexed.
        var index = FingerprintIndex()
        for media in bundledMedia {
            let url = bundleURL.appendingPathComponent(media.bundleRelativePath)
            let digest = try Fingerprint.sha256(of: url)
            index.entries[media.bundleRelativePath] = digest
        }

        try index.encoded().write(to: bundleURL.appendingPathComponent(ProjectBundleLayout.fingerprintsJSON),
                                  options: .atomic)
        try projectJSON.write(to: bundleURL.appendingPathComponent(ProjectBundleLayout.projectJSON),
                              options: .atomic)
        return index
    }

    // MARK: - Detection

    /// Whether the URL points to a `.lcbundle` directory. Used by the open path
    /// to dispatch between bundle and single-file loads.
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
