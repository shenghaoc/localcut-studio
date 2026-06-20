# Security & Safety

This is a sandboxed, offline, local-only app. "Security" here means **App Sandbox correctness, resource-lifetime safety, and no data loss** — not network hardening (there is no network surface in v1).

## App Sandbox & file access

- App Sandbox is **ON**. The app may read media the user explicitly selects and write exports to user-chosen locations only (`ENABLE_USER_SELECTED_FILES = readwrite`).
- Imported files are reached through **security-scoped** URLs: call `startAccessingSecurityScopedResource()` and retain access for as long as the asset is in use; balance it with `stop` on the matching lifetime. When the project document lands, persist access with **security-scoped bookmarks**, not raw paths.
- Never read or write outside user-selected locations. No writing into the app bundle, no `/tmp` for user content beyond `directoryForTemporaryFiles` during export.
- Add entitlements **only** when a concrete API fails without one — do not pre-grant capabilities (camera, mic, network) the editor doesn't use.

## Resource lifetime (memory-safety analogue)

The browser project's "close every `VideoFrame` exactly once" maps to:

- Remove `AVPlayer` periodic time observers and `NotificationCenter` observers in `deinit`.
- Cancel every `Task` you own (e.g. export progress task) on completion/cancellation.
- Don't retain `AVAssetImageGenerator`/`CVPixelBuffer`/`CIImage` beyond their use; generate thumbnails in a bounded batch.
- Avoid retain cycles: `[weak self]` in escaping observer/`Task` closures.

## Data safety

- Edits must never silently drop clips or tracks; destructive actions (delete, overwrite-on-export) require explicit user intent.
- Export removes an existing file at the destination only because the user picked that path in the save panel; never overwrite without that intent.
- No secrets, tokens, or credentials in source or committed config.

## Untrusted input

- Treat all media metadata (durations, natural sizes, transforms) as untrusted: validate/clamp before using in geometry or time math; never force-unwrap it.
