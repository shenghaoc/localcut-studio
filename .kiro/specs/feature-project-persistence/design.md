# Design: Project Persistence

> **Ownership note:** The custom file-based document controller remains; see [`feature-native-document-lifecycle`](../feature-native-document-lifecycle/design.md) for the DocumentGroup trade-off on macOS 26.


> Status: **Implemented**. Shipped in [#6](https://github.com/shenghaoc/localcut-studio/pull/6); schema since carried through later phases to the current version documented in [`docs/PROJECT_SCHEMA.md`](../../../docs/PROJECT_SCHEMA.md). See [tasks.md](./tasks.md) for the per-box source citations.

## Approach

Split the runtime model from a Codable document model. `Project` (runtime, holds live `AVURLAsset`s) is built from / written to a `ProjectDocument` (Codable, holds bookmarks + plain values). Use a versioned schema with lenient defaults for known top-level fields so older documents keep opening; decoded newer documents are treated as Save As-only downconversion sessions. Non-additive nested type changes can still fail decode and need explicit migrations.

## Pieces

- **`ProjectDocument: Codable`** — `schemaVersion`, `renderSize`, `frameRate`, `[MediaRef]` (bookmark data + display name + cached metadata), `[TrackDoc]` of `[ClipDoc]` (source range, timeline start, opacity, effects, transitions). `CMTime` encoded as value/timescale.
- **Load**: resolve each `MediaRef` bookmark with `URL(resolvingBookmarkData:options:.withSecurityScope...)`, start access, build `MediaItem`s, then reconstruct tracks/clips. Unresolved media → relink flow (status + picker), not a drop.
- **Save**: snapshot the runtime model to `ProjectDocument`, write atomically (`Data.write(options:.atomic)` or `FileWrapper` for a package).
- **Scene**: adopt `DocumentGroup` with a `FileDocument`/`ReferenceFileDocument`, or a custom `NSDocument`-style controller if `DocumentGroup` constrains the editor layout too much. Wire New/Open/Save/Save As + dirty state + window title.
- **Undo**: route every mutation in `EditorModel` through helpers that register inverse operations on `UndoManager` (capture pre/post `ClipDoc`/`TrackDoc` snapshots). Undo/redo apply the snapshot and `rebuild()`.

## Risks

- Bookmark resolution failures across machines/volumes — relink UX is required, not optional.
- Keeping undo granularity sensible (one user action = one undo step) while many ops also call `rebuild()`.
- `DocumentGroup` vs. custom controller trade-off: evaluate before committing T2.
