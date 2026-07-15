# Design: Project Persistence

> Status: **Implemented**. Shipped in [#6](https://github.com/shenghaoc/localcut-studio/pull/6); schema since carried through later phases to the current version documented in [`docs/PROJECT_SCHEMA.md`](../../../docs/PROJECT_SCHEMA.md). See [tasks.md](./tasks.md) for the per-box source citations.

## Approach

Split the runtime model from a Codable document model. `Project` (runtime, holds live `AVURLAsset`s) is built from / written to a `ProjectDocument` (Codable, holds bookmarks + plain values). Use a versioned schema with lenient defaults for known top-level fields so older documents keep opening; decoded newer documents are treated as Save As-only downconversion sessions. Non-additive nested type changes can still fail decode and need explicit migrations.

## Pieces

- **`ProjectDocument: Codable`** — `schemaVersion`, `renderSize`, `frameRate`, `[MediaRef]` (bookmark data + display name + cached metadata), `[TrackDoc]` of `[ClipDoc]` (source range, timeline start, opacity, effects, transitions). `CMTime` encoded as value/timescale.
- **Load**: resolve each `MediaRef` bookmark with `URL(resolvingBookmarkData:options:.withSecurityScope...)`, start access, build `MediaItem`s, then reconstruct tracks/clips. Unresolved media → relink flow (status + picker), not a drop.
- **Save**: snapshot the runtime model to `ProjectDocument`, write atomically (`Data.write(options:.atomic)` or `FileWrapper` for a package).
- **Scene**: the implemented path is a custom URL-based controller for
  New/Open/Save/Save As, dirty state, and window title. The later native
  lifecycle spike confirmed that macOS 26's synchronous
  `ReferenceFileDocument` / `FileWrapper` callbacks cannot preserve LocalCut's
  asynchronous URL-owned package staging, fingerprints, bookmarks, and
  security-scoped lifetime without duplicating or degrading this layer. See
  [Native document lifecycle](../feature-native-document-lifecycle/design.md).
- **Undo**: route every mutation in `EditorModel` through helpers that register inverse operations on `UndoManager` (capture pre/post `ClipDoc`/`TrackDoc` snapshots). Undo/redo apply the snapshot and `rebuild()`.

## Risks

- Bookmark resolution failures across machines/volumes — relink UX is required, not optional.
- Keeping undo granularity sensible (one user action = one undo step) while many ops also call `rebuild()`.
- A future migration must re-evaluate `DocumentGroup` only after the minimum
  deployment target can prove the asynchronous URL document APIs preserve the
  current package and security contract.
