# Requirements: Project Bundles

## R1 — Bundle format

- **R1.1** A `.lcbundle` is a directory the user-facing OS treats as one item (the UTType conforms to `.package`).
- **R1.2** A well-formed `.lcbundle` contains, at minimum, `project.json`. `fingerprints.json` and `assets/` are present when the bundle has at least one bundled media item.
- **R1.3** `project.json` is the existing `ProjectDocument` JSON shape with two added fields: `bundleFormat: "1"` at the top level, and an optional `bundleRelativePath` on each `MediaRef`. Both are optional from the decoder's perspective so single-file `.lcstudio` documents stay round-trip-compatible.
- **R1.4** `currentSchemaVersion = 3` on first bundle save; documents written into the single-file format keep `schemaVersion = 2` (the PR #10 value).
- **R1.5** Asset files inside `assets/` are named `<MediaItem.id>.<source-extension>` so renames in the bin don't perturb on-disk file names.

## R2 — Open

- **R2.1** Opening a `.lcbundle` reads `project.json`, resolves every `bundleRelativePath` against the bundle root without needing a security-scoped bookmark, and runs the existing bookmark-resolution path for any `MediaRef` without `bundleRelativePath`.
- **R2.2** Opening a `.lcstudio` continues to work unchanged — both UTTypes are accepted by the open panel.
- **R2.3** A missing or corrupt `fingerprints.json` is tolerated (the next save regenerates it).
- **R2.4** A bundled asset whose on-disk SHA-256 differs from `fingerprints.json` surfaces a user-visible warning in `statusMessage` (the project still opens; the user decides whether to relink).
- **R2.5** Mixed projects (some media bundled, some external-only via bookmark) load correctly. The two paths coexist on a single project.

## R3 — Save

- **R3.1** Saving as `.lcbundle` writes `project.json` atomically, copies every flagged media item into `assets/`, computes SHA-256 for each copied file, and writes `fingerprints.json`.
- **R3.2** Saving the same project a second time skips the copy step for any asset whose source SHA-256 matches the already-stored fingerprint (fast path).
- **R3.3** Saving as `.lcstudio` writes the legacy single-file JSON exactly as before — no `bundleFormat`, no `bundleRelativePath`, `schemaVersion = 2`.
- **R3.4** Save uses APFS clones / hard links where the same-volume source allows (`FileManager.copyItem(at:to:)` already does this).
- **R3.5** Atomicity: a failed save leaves the previous bundle directory untouched. The new `project.json` is written through a temp file inside the bundle; partial copies under `assets/` are tolerated because every successful copy is also recorded in `fingerprints.json` and re-checked on next save.

## R4 — Migration

- **R4.1** A **Convert to Bundle…** menu action is enabled when the current document is a single-file `.lcstudio`.
- **R4.2** Convert writes a new `<name>.lcbundle` alongside the original `.lcstudio` (or anywhere the user chooses in the save panel). The original `.lcstudio` is left untouched.
- **R4.3** Convert preserves every clip, caption (including stable caption-track UUIDs), preset, transition, effect, and undo history. The undo manager is **not** cleared by Convert; the user can still undo / redo edits made before conversion.
- **R4.4** After Convert succeeds, the runtime adopts the new bundle URL as the document URL; further saves go into the bundle.

## R5 — Sandbox

- **R5.1** Reading or writing files inside a `.lcbundle` directory the user just opened does not require a security-scoped bookmark; the user's grant on the bundle is the grant on its contents.
- **R5.2** External-only `MediaRef`s — media imported with the "Don't copy" option, or items not (yet) copied into the bundle — continue to use security-scoped bookmarks exactly as before.
- **R5.3** The two paths are documented in `design.md` (`## Sandbox`) and the `EditorModel+Persistence.swift` code references that section.

## R6 — Verification

- **R6.1** Unit test: saving a project to a bundle, reopening it, and re-saving preserves caption-track UUIDs (PR #10's stability guarantee must not regress through the bundle format).
- **R6.2** Unit test: writing a fingerprints index and then editing a tracked file externally produces a mismatch on re-fingerprint.
- **R6.3** Unit test: `.lcstudio` → `.lcbundle` conversion preserves every clip, caption, preset, effect, and transition; the original `.lcstudio` file is not modified; undo cleanup is not triggered by the conversion.
- **R6.4** Unit test: a project mixing copied (bundled) and bookmarked (external-only) media round-trips through the bundle save/load — the bundled refs get `bundleRelativePath`, the external refs keep their bookmark.
- **R6.5** `xcodebuild` (Debug, macOS) green; no test count regression from the post-PR #10 baseline.
