# Tasks: Project Bundles

> Status: **Implemented**. Lands alongside the Phase 30 follow-ups; Phase 34 / 38 / 48 can now adopt the bundle format.

## Format

- [x] **T1.1** Declare `UTType.lcStudioProjectBundle` (`com.localcutstudio.project-bundle`, conforming to `.package`) alongside the existing `lcStudioProject` in `ProjectDocument.swift`.
- [x] **T1.2** Bump `ProjectDocument.currentSchemaVersion` to 3. Single-file `.lcstudio` saves continue to write `schemaVersion = 2` to stay readable by older builds; bundle saves write 3.
- [x] **T1.3** Add `bundleFormat: String?` to `ProjectDocument` (`"1"` when written into a bundle, `nil` otherwise) and `bundleRelativePath: String?` to `MediaRef`. Both decode leniently.

## Fingerprints

- [x] **T2.1** Add `Fingerprint.sha256(of: URL)` (`CryptoKit.SHA256`, streamed in 256 KB chunks).
- [x] **T2.2** Add `FingerprintIndex` Codable type (`[bundleRelativePath: hex digest]`); the index serialises sorted-key JSON for stable diffs. (Determinism guarantee finished under [`bugfix-fingerprint-index-determinism`](../bugfix-fingerprint-index-determinism/tasks.md) — the manual sort alone wasn't sufficient on macOS 26.)

## Bundle I/O

- [x] **T3.1** Add `ProjectBundle.read(url:)`: opens the bundle, decodes `project.json`, reads `fingerprints.json` (missing OK), returns the document + the parsed index for the caller to verify on-disk asset state.
- [x] **T3.2** Add `ProjectBundle.write(_:to:bundledMedia:previousFingerprints:)`: creates the bundle directory, copies bundled media into `assets/<id>.<ext>` skipping copies that already match the stored fingerprint, stages `fingerprints.json` + `project.json`, then promotes them after both staged writes succeed. Returns the updated fingerprint index.

## Document lifecycle

- [x] **T4.1** `EditorModel.open(url:)` detects whether the URL is a directory and dispatches to bundle-load vs single-file-load. The existing single-file path is preserved; bundled assets resolve via direct file URLs (no security-scoped bookmark required — see R5.1).
- [x] **T4.2** `EditorModel.write(to:)` detects the URL extension. `.lcbundle` writes through `ProjectBundle.write`; `.lcstudio` writes the legacy single-file JSON.
- [x] **T4.3** `EditorModel.convertToBundle(url:)` builds a fresh `ProjectDocument` snapshot of the current project, copies every resolved media item into `assets/`, fingerprints them, writes the bundle, adopts the new URL — leaving the original `.lcstudio` untouched (R4.2 / R4.3).
- [x] **T4.4** Open panel accepts both `lcStudioProject` and `lcStudioProjectBundle`. Save panel defaults to `lcStudioProjectBundle` for new documents; the user can still pick `lcStudioProject` to keep the legacy format.
- [x] **T4.5** **Convert to Bundle…** command in the File menu, wired to `EditorModel.requestConvertToBundle()`. Disabled when the current document is already a bundle (or is unsaved — Save As goes straight to the bundle in that case).
- [x] **T4.6** Media-bin import UI exposes a "Copy into Bundle" checkbox; imported items carry the chosen `wantsBundling` value into bundle saves.

## Sandbox

- [x] **T5.1** When opening a bundle, do not allocate a security-scoped bookmark for bundled assets; rely on the outer bundle URL's grant. Document the split in `Sandbox` of `design.md`.
- [x] **T5.2** External-only refs (`bundleRelativePath == nil`) continue through the existing security-scoped bookmark path.

## Tests

- [x] **T6.1** `bundleRoundTripPreservesCaptionTrackIDs` — save a project with a caption track into a bundle, reopen, re-save, and assert the track UUID survives both round trips.
- [x] **T6.2** `fingerprintDetectsExternalEdit` — fingerprint a file, modify it on disk, re-fingerprint, and assert the digest changed.
- [x] **T6.3** `lcstudioConvertsToBundlePreservingEverything` — build a project with clips, captions, presets, effects, and a transition; convert to bundle; reopen the bundle; assert every field matches; assert the original `.lcstudio` content is byte-identical to before; assert undo-stack depth is unchanged by Convert.
- [x] **T6.4** `bundleMixedCopiedAndBookmarkedMedia` — round-trip a project whose media set is part bundled (with `bundleRelativePath`) and part external-only (with `bookmark`); assert each MediaRef takes the correct path on load.
- [x] **T6.5** `bundleMetadataStagingCleansUp` — bundle save writes both metadata files and leaves no `.staged-*` metadata files behind.
- [x] **T6.6** `bundleDocumentRespectsDontCopyImportFlag` — an imported item with `wantsBundling = false` remains bookmark-backed with no `bundleRelativePath` in bundle JSON.

## Documentation

- [x] **T7.1** Move the **Project bundles (P23)** row in `.kiro/specs/ROADMAP.md` out of the "Open infra" table into the "Existing spec" table, alongside the other prerequisite feature specs.
- [x] **T7.2** Note in `design.md` that Phase 30 was implemented before bundles landed and uses the simpler single-file format; the migration path lets existing Phase 30 projects upgrade.

## Verification

- [x] **V1** `xcodebuild` (Debug, macOS) green.
- [x] **V2** No test count regression from the post-PR #10 baseline (existing 90+ tests still pass; new tests are additive).
