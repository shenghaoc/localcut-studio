# Project Document Schema

This document describes the versioning and compatibility model for LocalCut Studio project files (`.lcstudio` and `.lcstudiobundle`).

## Current schema version

| Format | Version |
|--------|---------|
| Bundle (`.lcstudiobundle`) | 10 |
| Single-file (`.lcstudio`) | 10 |

Both formats share the same `ProjectDocument` structure. The version is stored in the `schemaVersion` JSON key.

## Version history

| Version | Phase | Fields added |
|---------|-------|--------------|
| 1–4 | 1–38 | `name`, `renderWidth`, `renderHeight`, `frameRate`, `media`, `videoTracks`, `audioTracks`, `captionTracks`, `markers` |
| 5–6 | 38a | Look effects on clips |
| 6–7 | 38b | `overlays` (OverlayClip persistence) |
| 8 | 43 | `callouts`, `paddedBackground`, `screencastEventLogs`, per-clip `transformKeyframes` |
| 9 | 44 | `keystrokeOverlayClips` |
| 10 | 45 | `sceneDoc`, `layoutTracks` |

> **Note:** Phase 39 added `aspect` and `coverFrame` but did not bump the schema version. These fields decode with defaults on older documents.

## Compatibility model

LocalCut Studio uses **forward-compatible decoding**: every field in `ProjectDocument` is decoded with `decodeIfPresent` and a safe default. Unknown JSON keys are silently ignored by `JSONDecoder`.

### Opening an older project (schemaVersion < current)

The project opens normally. Missing fields receive their defaults:

| Missing field | Default |
|---------------|---------|
| `schemaVersion` | `currentSchemaVersion` (10) |
| `name` | `"Untitled"` |
| `renderWidth` | `1920` |
| `renderHeight` | `1080` |
| `frameRate` | `30` |
| `workingColourSpace` | `.sRGB` |
| `media`, `videoTracks`, `audioTracks`, `captionTracks`, `markers`, `overlays`, `callouts`, `screencastEventLogs`, `keystrokeOverlayClips`, `layoutTracks` | `[]` |
| `audioBus` | `AudioBusDoc()` (gain 1, no track inputs, default voice cleanup) |
| `aspect` | inferred from render width/height |
| `paddedBackground`, `coverFrame` | `nil` |
| `sceneDoc` | `SceneDoc()` (empty) |

Per-clip fields (`opacity`, `effects`, `transition`, `geometry`, `volumeEnvelope`, `speedCurve`, `preservePitch`, `pitchAlgorithm`, `transformKeyframes`) also default to safe values.

### Opening a newer project (schemaVersion > current)

The project **opens read-only**. The app:

1. Decodes the document (unknown keys are ignored, missing fields get defaults).
2. Sets `documentURL = nil` so the document saves via Save As rather than overwriting the original.
3. Marks the document as dirty, prompting "Save As" on close.
4. Shows a status message: *"saved in a newer format — saving downconverts to this version"*.

This prevents silent data loss: the user must explicitly choose to save a downconverted copy.

### Saving always writes the current schema

Every save writes `schemaVersion = currentSchemaVersion` (or `singleFileSchemaVersion`). The project is always persisted in the latest known format, regardless of what version it was opened from.

## Lenient decoding

Two fields use extra-lenient decoding to avoid failing on malformed or future values:

- **`aspect`**: An unknown raw value falls back to inference from render width/height rather than throwing.
- **`coverFrame`**: A malformed cover frame decodes to `nil` instead of failing the entire document open.

## Migration functions

The codebase includes `migrateSceneDoc(_:)` as the designated entry point for schema upgrades. Currently it stamps `schemaVersion = sceneSchemaVersion` on every read (V1 → V1, a no-op in effect). Future schema bumps should add migration logic before the stamp, gated on the document's `schemaVersion`.

No other explicit migration functions exist. The `decodeIfPresent`-with-defaults pattern serves as the implicit migration strategy.

## Known limitations

### Silent field loss on save by older versions

If a project created in v0.2 (schema 10) is opened in v0.1 (schema < 10), the older version will:

1. Decode the document successfully (unknown keys are ignored).
2. Save it with its own `currentSchemaVersion`.
3. **Drop any fields it does not know about** (e.g., `sceneDoc`, `layoutTracks`, `keystrokeOverlayClips`).

This is a one-way data loss: the newer fields are permanently removed from the file. There is no warning in the older version.

### No automatic upgrade path for removed features

If a field is removed in a future version, old documents still containing that field will have it silently ignored on decode. The field data persists in the JSON until the document is re-saved.

### Bundle format version is separate

The `bundleFormat` string (currently `"1"`) tracks the bundle directory layout, not the document schema. A bundle can have `schemaVersion = 10` with `bundleFormat = "1"`.

## When explicit migrations would be needed

The current `decodeIfPresent`-with-defaults strategy works when:

- New fields are additive and have sensible defaults.
- Old fields are optional and can be ignored.

Explicit migrations become necessary when:

1. **A field's semantics change** — the same JSON key means something different in a new version.
2. **A field is renamed** — the old key must be read and mapped to the new key.
3. **A field's type changes** — the old type cannot decode into the new type.
4. **Default values are insufficient** — the correct value depends on other fields or requires user input.
5. **Data must be transformed** — e.g., splitting one field into two, or merging fields.
6. **A field is removed** — old documents still contain the key; its data may need to be mapped to new fields before discarding.

In these cases, add a migration function called from `init(from:)`, gated on `schemaVersion < N`. The `migrateSceneDoc` function is the pattern to follow.

## Test coverage

The following tests verify schema compatibility:

- `PersistenceTests.documentCarriesSchemaVersion` — round-trip preserves version.
- `PersistenceTests.decodesUnknownKeysAndFutureVersion` — schema 99 with unknown keys decodes.
- `PersistenceTests.decodesWithDefaults` — empty JSON decodes with all defaults.
- `ColourManagementTests.legacyDocumentDecodesAsSRGB` — schema 2 without `workingColourSpace` defaults to sRGB.
- `ColourManagementTests.unknownWorkingSpaceDecodesAsSRGB` — unknown enum value falls back safely.
- `CaptionsAndKeyframesTests.projectDocumentSchemaV2` — verifies schema version >= 2.
- `CaptionsAndKeyframesTests.captionPersistenceLegacyDoc` — legacy document (schema 1) without `captionTracks` decodes to empty.
- `MarkersTests.schemaVersionBumped` — verifies schema version >= 3.
- `AudioMasterBusTests.schemaVersionAdvancesToV3` — verifies schema version >= 3.
- `ProjectBundleTests.singleFileSaveDownconvertsSchemaVersion` — single-file save uses `singleFileSchemaVersion` with no `bundleFormat`.

## Relevant source files

- `Packages/LocalCutCore/Sources/LocalCutCore/Models/DocumentTypes.swift` — `ProjectDocument` Codable conformance.
- `LocalCut Studio/DocumentController.swift` — open/save logic, schema version check.
- `LocalCut Studio/EditorModel+Persistence.swift` — core persistence wiring.
- `Packages/LocalCutCore/Sources/LocalCutCore/Models/SceneModels.swift` — `migrateSceneDoc`.
- `LocalCut StudioTests/PersistenceTests.swift` — schema compatibility tests.
