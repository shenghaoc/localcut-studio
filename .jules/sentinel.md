# Sentinel — Security & Safety Journal

Append a dated entry whenever you learn something about LocalCut Studio's sandbox correctness, resource-lifetime safety, or data-loss avoidance. (There is no network surface in v1; "security" here is local safety.) Format: **Vulnerability/Risk** + **Learning** + **Prevention**.

## 2026-06-21 — Security-scoped access must be balanced

**Risk:** `.fileImporter` / `NSOpenPanel` URLs require `startAccessingSecurityScopedResource()` to read under the sandbox. Calling it without a matching `stop`, or stopping it while the `AVAsset` is still in use, either leaks the scope or breaks playback/export mid-operation.
**Learning:** The scope must outlive every use of the asset (preview item + export), so it's retained for the session — but that retention must be released on the matching lifetime, and persisted across launches via a **security-scoped bookmark**, never a raw path.
**Prevention:** Acquire on import, release on project close / item removal; when persistence lands, store bookmarks and re-resolve with `.withSecurityScope`. Treat a failed `start...` as an import error surfaced to `statusMessage`, not a silent drop.

## 2026-06-21 — Export must not overwrite without intent

**Risk:** `AVAssetExportSession` fails if the destination exists, so it's tempting to blindly `removeItem(at:)` first.
**Learning:** Removing the file is only safe because the user picked that exact path in `NSSavePanel` (which itself confirms overwrite). Doing it for any other reason is data loss.
**Prevention:** Only delete-then-write at a URL the user just chose via the save panel; never derive an output path and overwrite silently.
