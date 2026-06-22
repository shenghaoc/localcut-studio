# Design: Project Bundles (P23 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 30 (already merged with the simpler single-file doc — the migration path lets existing Phase 30 projects upgrade), Phase 34 (beat tools), Phase 38 (look packs), and Phase 48 (OTIO export).

## Goal

Move the project document from a single JSON file (`.lcstudio`) to a **directory package** (`.lcbundle`) that bundles the JSON together with copies (or hard links) of the media it references and a sidecar of file fingerprints. The package looks and behaves as one item in Finder — double-clicking it opens the project; copying it copies the media; emailing the zip ships a self-contained edit.

The single-file `.lcstudio` format keeps working and is the migration source. Existing Phase 30 projects open unchanged and can be **Converted to Bundle…** in one menu action, which writes a new `.lcbundle` alongside the original and leaves the original untouched.

## Bundle layout

```
MyProject.lcbundle/                       (directory, declared as a UTType conforming to .package)
├── project.json                          ProjectDocument JSON; v3 schema with bundleFormat: "1"
├── fingerprints.json                     SHA-256 of every file under assets/, keyed by relative path
└── assets/                               copies (or APFS clones / hard links) of imported media
    ├── 6E8D…F2.mov                       file name = MediaRef.id (UUID).extension
    ├── 6E8D…F2.mov.json                  (optional, future) per-asset metadata sidecar
    └── …
```

- **`project.json`** — exactly the existing `ProjectDocument` JSON shape, with two additions: a `bundleFormat: "1"` field at the top level so an old reader can tell at a glance, and an optional `bundleRelativePath: "assets/<id>.<ext>"` on each `MediaRef`. The `bookmark` field is preserved either way — see *Sandbox* below.
- **`assets/`** — copies of every media item the user chose to *include* in the bundle. Items the user chose **not** to include (the "Don't copy" path) still appear in `project.json` but only with a bookmark, not a `bundleRelativePath`.
- **`fingerprints.json`** — SHA-256 of every file under `assets/`, keyed by the bundle-relative path:
  ```json
  { "assets/6E8D…F2.mov": "0bd3…ab" }
  ```
  Used both to detect external edits (an asset modified on disk while the bundle was elsewhere) and to skip recopying on save when the source matches an existing bundled copy.

## UTType

```swift
extension UTType {
    static let lcStudioProjectBundle = UTType(
        exportedAs: "com.localcutstudio.project-bundle",
        conformingTo: .package)
}
```

Conforming to `.package` is the key step: it makes Finder treat the directory as a single, double-clickable item, hides the inner files from casual browsing, and gates copy/move on the whole bundle rather than per-file. The existing `lcStudioProject` UTType is preserved for opening old documents; the open panel accepts both.

Full Finder double-click integration on a fresh install still needs an Info.plist `UTExportedTypeDeclarations` entry — the dynamic UTType is enough for in-app New/Open/Save/Save As under the sandbox, but Launch Services only learns about a custom package type from a bundled Info.plist. Wiring that into the Xcode `INFOPLIST_KEY_*` build settings is a small follow-up outside this spec's scope; the in-app path is fully functional today.

## Save path

1. The save panel's default content type is `lcStudioProjectBundle`. The user can pick `lcStudioProject` to keep the old single-file shape.
2. **Bundle save** (`ProjectBundle.write(_:to:fingerprintCache:)`):
   1. Create / reuse the `.lcbundle` directory.
   2. For each media item that the user has flagged as *bundled* (the default for newly-imported media), compute the SHA-256 of its source URL.
      - If `fingerprints.json` already contains an entry for the target `assets/<id>.<ext>` whose digest matches, **skip the copy** (fast path). The asset is already in the bundle.
      - Otherwise, `FileManager.copyItem(at:to:)` — APFS clone where the same volume allows, plain copy across volumes.
   3. Re-compute fingerprints over `assets/` and rewrite `fingerprints.json`.
   4. Write `project.json` atomically via the same JSON encoder used for `.lcstudio`. The `bundleFormat` field is set to `"1"`; `schemaVersion` is bumped to 3 on first bundle save. `MediaRef.bundleRelativePath` is filled in for every bundled asset.
3. **Single-file save** stays the existing path (atomic JSON write); `schemaVersion` stays at 2 for backwards-readability.

The on-disk fingerprint cache survives across saves so a second save doesn't re-hash files that haven't changed. The cache is *also* used at load to detect external edits (an asset modified while the bundle was elsewhere) and flag a relink prompt.

## Open path

1. Detect whether `url` is a directory; if so, treat it as a bundle.
2. **Bundle open** (`ProjectBundle.read(_:)`):
   1. Read `project.json` as `Data`, decode into `ProjectDocument`.
   2. Read `fingerprints.json` (missing file is tolerated — a bundle authored by hand may not have one yet; we generate one on the next save).
   3. For each `MediaRef` with a `bundleRelativePath`, resolve to `bundleURL.appendingPathComponent(bundleRelativePath)`. **No security-scoped bookmark required** — the user granted access to the bundle directory when they opened it; that grant covers everything inside.
   4. For each `MediaRef` without a `bundleRelativePath`, resolve through the existing security-scoped bookmark path (mixed bundle + external-only media is supported).
   5. Verify each bundled asset's SHA-256 against `fingerprints.json`. A mismatch surfaces in the status bar so the user can choose to relink, replace, or accept.
3. **Single-file open** uses the existing path; on first save, the user is prompted: keep `.lcstudio`, or convert to `.lcbundle`.

## Migration (`Convert to Bundle…`)

The File menu gains a **Convert to Bundle…** item, enabled whenever the current document is a single-file `.lcstudio`:

1. Run `NSSavePanel` defaulted to the document's directory with `<name>.lcbundle` and `lcStudioProjectBundle` as the only content type.
2. Build a fresh `ProjectDocument` snapshot (including the schema-version bump to 3 and `bundleFormat: "1"`).
3. Copy every resolved media item into `assets/`, fingerprint them, write `fingerprints.json` + `project.json`.
4. Adopt the new URL as the document URL. The original `.lcstudio` file is left untouched — the user can delete it manually after sanity-checking the bundle.
5. The status bar reports `Converted "<name>" to bundle — original .lcstudio left in place.`

Phase 30 was implemented before bundles landed and uses the simpler single-file format; this migration path lets every Phase 30 project upgrade in one click without touching its arrangement, captions, presets, or undo history.

## Sandbox

The App Sandbox treats a user-selected directory as a single grant: opening `MyProject.lcbundle` from the open panel hands the app read/write access to *everything inside*. That means:

- **Bundled assets (`assets/<id>.<ext>`)** need **no per-file security-scoped bookmark.** The bundle's outer URL is the grant; we read media directly off the bundled path. The `bookmark` field on `MediaRef` is left empty for bundled-only media.
- **External-only references** (the "Don't copy" path chosen at import time, or media not yet copied into the bundle) **continue to use security-scoped bookmarks.** The `bookmark` field on those `MediaRef`s is populated exactly as before, and resolved at load via `URL(resolvingBookmarkData:options:.withSecurityScope...)`. The relink flow is unchanged.
- A bundle moved between machines carries its `assets/` along, so the relink flow is rarely needed in practice for bundled projects. Bookmarks across machines have always been brittle; bundles fix that for the common case.

The split is the single most important sandbox change the bundle format makes — documented here so the relink and import paths in `EditorModel+Persistence.swift` stay coherent across the two backing formats.

## Fingerprints

```swift
enum Fingerprint {
    static func sha256(of url: URL) throws -> String  // hex string
}

struct FingerprintIndex: Codable, Equatable {
    var entries: [String: String]   // bundle-relative path → hex digest
}
```

Computation streams the file through `CryptoKit.SHA256` in 256 KB chunks so a 4 GB master copy doesn't pull into RAM. The hex string is lowercase, no separators. The index is sorted on write for stable JSON diffs.

`fingerprints.json` lives in the bundle root rather than inside `assets/` so a sweep of `assets/` is a pure media-file listing.

## Codable / schema

`ProjectDocument` gains:

```swift
static let currentSchemaVersion = 3
var bundleFormat: String?              // "1" when written into an .lcbundle; nil for legacy single-file
```

`MediaRef` gains:

```swift
var bundleRelativePath: String?        // "assets/<id>.<ext>" when copied into the bundle
```

Both fields are **optional** so any decoder — including a v2 single-file build — opens a v3 bundle's `project.json` without surprise. On the bundle save path, `bundleRelativePath` is filled in for every bundled asset. On the single-file save path, it is omitted.

Lenient decoding is the existing pattern (`decodeIfPresent` everywhere); no behavioural change to the decode side beyond the new optional keys.

## Trade-offs

- **Directory package vs. zip / SQLite container.** A `.package` directory is what Final Cut, Logic, and Photos all use — the native macOS NLE expectation. A zip would seal-and-ship cleanly but every save would rewrite the whole archive; SQLite would hide media from quicklook and gain almost nothing.
- **APFS clone / hard link vs. plain copy.** When the source is on the same volume, we clone (`FileManager.copyItem(at:to:)` already does this on APFS — no extra API). Cross-volume falls back to a real copy.
- **One canonical asset name (`<id>.<ext>`)**. Using the media UUID as the filename keeps the on-disk layout stable across renames in the bin and lets the fingerprints index stay simple.
- **Optional `bundleFormat` field, not `currentBundleFormatVersion`**. Versioning the schema is the cross-format concern; versioning the bundle's internal format separately gives us room to evolve `assets/` (e.g. proxies, render cache) without re-versioning the document schema.

## Risks

- **Asset name collisions across volumes.** Two media items pointed at different files with the same source filename would collide if we used the source filename. Using the UUID-derived name avoids this entirely.
- **Save during in-flight import.** A bundle save mid-import would copy an only-partly-known media set. The existing `sessionGeneration` guard already gates async work; we extend it to the copy phase.
- **Bundle on a remote volume.** Network volumes don't always preserve atomicity guarantees; `Data.write(options:.atomic)` on `project.json` lands the new content via a tmpfile-then-rename, which is the same shape network volumes already optimise for.
- **A user manually editing an asset inside the bundle.** The fingerprint check on the next open surfaces the mismatch; the user gets a clear "this file changed externally" status message and can choose to accept or relink.

## Non-goals

- **No proxy / render cache yet.** Phase 19's render cache slots cleanly into a future `bundle/Caches/` subdirectory, but is not part of this spec.
- **No per-asset metadata sidecar yet.** A `assets/<id>.<ext>.json` for waveform peaks / thumbnails is reserved but not written here.
- **No Quick Look bundle preview.** Default Finder behaviour applies; a thumbnail provider is a follow-up.
- **No automatic .lcstudio cleanup on conversion.** The migration leaves the original alone so the user can verify the bundle first.
- **No multi-document support inside one bundle.** One project = one bundle.
