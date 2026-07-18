# Design: Native Document Lifecycle

> Status: **Implemented** on `feature/native-document-lifecycle`.

## Decision

**No-go for a production `DocumentGroup` / `ReferenceFileDocument` migration on
the macOS 26 deployment baseline. Go for the independent SwiftUI shell
cleanup.**

`DocumentGroup` is technically feasible, but macOS 26’s `ReferenceFileDocument`
interface does not directly reuse LocalCut’s existing filesystem-URL-based
asynchronous package pipeline. Adopting it now would require a second bundle
persistence implementation, so this PR retains the custom file-based
controller.

A compile-tested probe in
`LocalCut StudioTests/DocumentGroupCompatibilityTests.swift` shows that a
`ReferenceFileDocument` can advertise both a flat `.lcstudio` type and a
directory/package `.lcbundle` type, and that it can be passed to the macOS 26
`DocumentGroup` initializer. That is an API-compatibility fact, not a proof that
production package I/O is impossible or unsafe in general.

### Local filesystem URL (terminology)

In this feature, **URL** means a Foundation local filesystem location such as:

```text
file:///Users/example/Documents/MyProject.lcbundle/
```

It does **not** mean an HTTP endpoint. The custom controller needs the
user-selected local filesystem URL so it can keep security-scoped access
balanced while staging atomic package writes, copying media, computing
fingerprints, resolving bookmarks, and performing asynchronous load / relink /
rebuild work. macOS 26 `ReferenceFileDocument` callbacks provide a `FileWrapper`
snapshot, not that filesystem-URL-based package pipeline.

Revisit when the supported deployment baseline offers document APIs that cleanly
expose the lifecycle required by LocalCut’s package pipeline.

## Why the original persistence feature used a custom controller

The original persistence design deliberately left `DocumentGroup` versus a
custom controller as a lifecycle decision, then selected the custom controller
in T2.1. It still fits the single-editor / single-`AVPlayer` shell. The stronger
reason today is that adopting `DocumentGroup` would force a second persistence
implementation beside the existing package pipeline.

## Architecture answers from the compatibility probe

| Question | Result on macOS 26 |
|---|---|
| 1. One type for `.lcstudio` and `.lcbundle`? | **Technically yes** for content-type advertisement. This does not retain real package I/O semantics. |
| 2. Async loading / bookmark resolution / relinking / rebuild without main-actor blocking? | **No clean reuse path.** Synchronous wrapper-based callbacks would require a second persistence implementation. |
| 3. Dirty, undo, save-on-close? | **Partial only.** DocumentGroup can drive edited state, but LocalCut still needs a close veto for recording and asynchronous save-before-close. |
| 4. Recording guards for New/Open/Close? | **Not safely by scene APIs alone.** Existing model guards and `NSWindowDelegate.windowShouldClose` remain required. |
| 5. Queued exports and security-scoped destinations independent of saves? | **Yes.** Save-panel exports bookmark the exact selected file; older directory bookmarks remain supported. |
| 6. Reliable App Intents with one editor? | **Yes.** `ActiveEditorRegistry` waits for editor-window readiness on cold launch and serializes actions. |
| 7. Schema and package structure unchanged? | **Yes** with the custom controller. |

## Selected implementation

### Document ownership

The shell still has one process-wide `EditorModel` created by
`LocalCutStudioAppState`. This feature does **not** claim multi-document GUI
support. `DocumentController` remains the owner of New, Open, Open Recent,
Save, Save As, recent-document registration, local filesystem URL state, and
persistence transactions.

`ProjectLocationInspector` is the single full-classification path for Open and
panel validation. Open Recent constructs its menu from URL-only candidates so
it never performs filesystem I/O on the main actor; selecting a candidate
revalidates it off the main actor before loading. It records an explicit
`ProjectStorageKind` (`.singleFile` or `.bundle`) after successful open or Save As. Save and queued
bundle-asset snapshots dispatch from that stored kind; Save As dispatches from
the panel-selected destination representation. A directory is never accepted
merely because a file named
`project.json` exists — metadata must decode as a supported `ProjectDocument`
with a supported `bundleFormat`. Classification rejects project metadata larger
than 10 MiB before reading or decoding it, so a renamed media file cannot force
an unbounded synchronous allocation during open-panel validation.

### Window state and commands

- Inspector visibility uses `@SceneStorage("editor.inspectorVisible")` with a
  focused binding for the View menu.
- `TimelineView` uses focused `onKeyPress` and pure `TimelineShortcutPolicy`.
  Initial focus is one-shot; subsequent appears do not steal focus from text
  fields or controls. Clicking the timeline reclaims shortcut focus.
- Scene modifiers provide default size, fitted placement, ideal placement, and
  automatic restoration.
- OTIO/EDL use in-memory serialization + `fileExporter`. Queued video render
  output remains `NSSavePanel` (streamed AVFoundation destination with a
  security-scoped bookmark). Because the sandbox grant belongs to the selected
  output file rather than its parent directory, a new destination is reserved
  as an empty file before its bookmark is encoded. The queue replaces that
  reservation when rendering starts. Enqueue rejection removes it immediately;
  failed/cancelled jobs keep it for Retry, and Clear Finished removes an empty
  reservation.

### App Intent readiness

`ActiveEditorRegistry` answers only “is the editor window available?” for the
single process-wide model. Cold-launch New Project / Diagnostics / Import /
Export wait for readiness (cancellation-safe continuation, bounded timeout).
Window-dependent queued actions are pinned to the ready-window generation that
awakened their cold launch; an action that loses that editor fails with
`targetWindowClosed` rather than retargeting a replacement. There is no
multi-document identity map keyed by `ObjectIdentifier`.

### AppKit that intentionally remains

`WindowConfigurator` mirrors dirty state and the represented local filesystem
URL, marks the editor ready on key-window activation, and vetoes close during
recording or asynchronous save. `SplitViewAutosaveConfigurator` remains for
divider persistence with the collapsed inspector invariant.

## Compatibility and follow-up

No project schema, `.lcstudio` encoding, `.lcbundle` layout, fingerprints,
relinking semantics, or render output format changes. The version-1 render
queue document gains an optional reservation flag; older queue JSON decodes it
as absent, and directory bookmarks from older builds remain supported.
Without a bundled Launch Services declaration, File ▸ Open validates a selected
local filesystem URL as either a regular `.lcstudio` file or a fully validated
bundle directory; Finder double-click is not newly advertised.

## Manual verification

See the native lifecycle checklist in `.kiro/steering/testing.md`. Two-document
GUI checks are not applicable under the single-editor architecture.
