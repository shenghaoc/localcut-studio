# Design: Native Document Lifecycle

> Status: **Implemented** on `feature/native-document-lifecycle`.

## Decision

**No-go for a production `DocumentGroup` / `ReferenceFileDocument` migration on
the macOS 26 deployment baseline. Go for the independent SwiftUI shell
cleanup.**

The decision is not based on preserving the current controller by habit. A
compile-tested probe in
`LocalCut StudioTests/NativeDocumentLifecycleSpikeTests.swift` proves that a
`ReferenceFileDocument` can advertise both a flat `.lcstudio` type and a
directory/package `.lcbundle` type, and that it can be passed to the macOS 26
`DocumentGroup` initializer. That is a useful API fact, but not an acceptable
replacement for LocalCut's production persistence contract.

`ReferenceFileDocument` on macOS 26 provides synchronous
`init(configuration:)`, `snapshot(contentType:)`, and
`fileWrapper(snapshot:configuration:)` callbacks. Its read/write configurations
provide a `FileWrapper`, not the document URL or an asynchronous streaming
transaction. The newer URL-oriented `Document` / `URLDocumentConfiguration`
APIs present in the installed macOS 27 SDK are unavailable at the app's macOS
26 target.

`DocumentController` and `ProjectBundle` need the actual selected URL to keep
security-scoped lifetime balanced while they stage atomic package writes, copy
media, calculate fingerprints, resolve bookmarks, preserve package layout, and
perform asynchronous load/relink/rebuild work. Recreating those behaviours by
materializing a whole package in a synchronous `FileWrapper` adapter would
duplicate persistence logic, risk main-actor blocking and memory spikes, and
weaken an already-tested atomic-save contract. The spike therefore disproves
the preferred architecture **for this target**, rather than proving that the
formats themselves cannot be documents.

## Why the original persistence feature used a custom controller

The original persistence design deliberately left `DocumentGroup` versus a
custom controller as a lifecycle decision, then selected the custom controller
in T2.1. At the time it also fit the single-editor / single-`AVPlayer` shell.
The current investigation confirms a stronger, still-applicable reason:
URL-owned asynchronous package and security-scoped I/O cannot be represented
faithfully by macOS 26's synchronous `ReferenceFileDocument` adapter without a
second persistence implementation. The custom controller remains a deliberate
compatibility boundary, not a default to preserve indefinitely.

## Architecture answers from the spike

| Question | Result on macOS 26 |
|---|---|
| 1. One type for `.lcstudio` and `.lcbundle`? | **Technically yes.** The probe produces both a regular `FileWrapper` and a directory wrapper. This does not retain real package I/O semantics. |
| 2. Async loading / bookmark resolution / relinking / rebuild without main-actor blocking? | **No clean path.** `ReferenceFileDocument` callbacks are synchronous and wrapper-based; adapting the existing URL services would duplicate or degrade them. |
| 3. Dirty, undo, save-on-close? | **Partial only.** DocumentGroup can drive edited state, but LocalCut still needs a close veto for recording and asynchronous save-before-close; SwiftUI has no equivalent close-veto hook. |
| 4. Recording guards for New/Open/Close? | **Not safely by scene APIs alone.** Existing model guards and `NSWindowDelegate.windowShouldClose` remain required. |
| 5. Queued exports and security-scoped destinations independent of saves? | **Yes, unchanged.** The render queue retains its own folder bookmark and output name. |
| 6. Reliable active-document App Intents? | **Yes for registered editors.** `ActiveDocumentRegistry` captures the active token and serializes routing. Cold launch before registration returns `noActiveDocument`. |
| 7. Schema and package structure unchanged? | **Yes with the selected custom controller.** A full adapter would require duplicate persistence code, so it is intentionally not adopted. |

## Selected implementation

### Document ownership

The current shell still has one `EditorModel` created by
`LocalCutStudioAppState`; this feature does **not** claim multi-document GUI
support. `DocumentController` remains the owner of New, Open, Open Recent,
Save, Save As, recent-document registration, URL state, and persistence
transactions. `EditorModel` remains the owner of its `AVPlayer`, editor runtime
state, undo manager, capture state, and render queue.

The new `ActiveDocumentRegistry` removes the router's direct ownership of that
global model. An editor registers on appearance and key-window activation;
queued App Intent actions capture a stable token, re-resolve it just before
execution, and fail with `targetDocumentClosed` if that editor went away. The
registry is deliberately capable of holding multiple independently-created
models, which protects future per-document work without falsely advertising it
today.

### Window state and commands

- Inspector visibility moved from `EditorModel` / app-wide `UserDefaults` to
  `@SceneStorage("editor.inspectorVisible")`. `FocusedBinding` lets the View
  menu toggle only the key scene.
- `TimelineView` uses focused `onKeyPress` and a pure
  `TimelineShortcutPolicy`; raw key codes, local monitors, and first-responder
  inspection were deleted. A marker consumes Delete only when selected; clip
  and transition deletion remains the semantic scoped delete command.
- Scene modifiers provide the default size, fitted first placement, ideal
  placement, and automatic restoration. Manual frame detection, deferred
  `setFrame`, and its one-shot `UserDefaults` flag are removed.
- OTIO and EDL are fully serialized in memory, so the key scene presents them
  with `fileExporter`. A `confirmationDialog` chooses an EDL video track when
  needed. Queued video render output remains an `NSSavePanel`, because it is a
  streamed AVFoundation destination with a persisted security-scoped bookmark.
- Ordinary media import already uses `fileImporter` in `MediaBinView`. The
  cancellation-aware `NSOpenPanel` used by the async model/App Intent command
  is retained so Shortcuts keeps the existing `EditorCommandOutcome` contract.

### AppKit that intentionally remains

`WindowConfigurator` is now a narrow bridge. It mirrors dirty state and the
represented URL, forwards key-window activation to the registry, and vetoes a
close while the model performs its recording guard or asynchronous save. It no
longer owns placement or restoration. `SplitViewAutosaveConfigurator` also
remains: the installed SwiftUI APIs do not persist divider positions while
preserving the collapsed inspector's saved expanded width.

## Compatibility and follow-up

No project schema, project UTI declaration, `.lcstudio` encoding, `.lcbundle`
layout, bundle fingerprints, bookmark model, relinking semantics, or render
queue persistence changes in this feature. Without a bundled Launch Services
declaration, File ▸ Open keeps its existing in-app role: it validates a selected
URL as either a regular `.lcstudio` file or a real bundle directory, but Finder
double-click / cold file-open is not newly advertised. The correct revisit point
is when the minimum deployment target can use the asynchronous macOS 27 document
APIs; that future spike must again prove URL, package, close-veto, recording,
and security-scope equivalence before a migration.

## Manual verification

See the native lifecycle checklist in `.kiro/steering/testing.md`. Since the
selected architecture does not create one editor model per native document
scene, the two-document GUI check is intentionally marked not applicable;
registry tests cover multiple independently registered editors instead.
