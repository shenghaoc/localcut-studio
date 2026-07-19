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

## 2026-06-21 - Untrusted Media Metadata Validation

**Vulnerability:** Untrusted external media file metadata like `duration`, `naturalSize`, and `preferredTransform` were being loaded directly into internal properties without sanitization. Maliciously crafted or corrupted video files could inject NaN, infinite, or negative values.
**Learning:** This could lead to infinite loops, division by zero, layout crashes, or DoS when rendering the UI or calculating timeline mathematics, due to invalid geometric and timing values.
**Prevention:** All metadata parameters must be validated and clamped before assignment. A set of `.sanitized` computed properties for `CMTime`, `CGSize`, and `CGAffineTransform` ensures values fall back to safe zero or identity states.

## 2026-06-23 — Remove Force Unwraps

**Vulnerability:** Found a force unwrap (`!`) when accessing values from a dictionary using its sorted keys in `ProjectBundle.swift`.
**Learning:** While iterating over `.keys` usually guarantees presence, force unwraps violate the "never force-unwrap" project security philosophy and pose a crash (Denial of Service) risk in Swift.
**Prevention:** Iterate dictionary entries directly with `entries.sorted(by:)` instead of subscripting by sorted keys, eliminating both the force-unwrap and any possibility of a silent skip.
## 2026-06-28 — Sanitize Media Metadata Before Use
**Vulnerability:** Untrusted user input via media metadata was not fully validated upon project reconstruction from document or queues, creating potential vector for crash via negative/infinite durations or huge canvas sizes.
**Learning:** App Sandbox security extends beyond file access—it means treating media parameters as adversarial input that must be bounded to avoid crashing rendering pipeline/timecode string conversion.
**Prevention:** Always use `.sanitized` property defined in `LocalCutCore` on `CMTime`, `CGSize`, and `CGAffineTransform` before ingesting media values into model domain.
## 2026-06-28 — Avoid Force Unwraps in Media processing
**Vulnerability:** Found force unwraps (`!`) in `BeatDetectionCore.swift` and `CaptureCoordinator.swift`.
**Learning:** Force-unwrapping poses a Denial of Service (crash) risk if the application receives unexpected inputs or if the assumption about the data structure's content fails.
**Prevention:** Always use safe optional binding (`if let`, `guard let`) when dealing with optional variables, especially when those variables depend on complex parsing logic, hardware configuration, or external media processing.
## 2026-07-06 — Force Unwrap Vulnerability Mitigation
**Vulnerability:** Force unwraps (`!`) were discovered in various files like `EdlSerializer.swift`, `Time.swift`, `CaptureRunningSessions.swift`, and `EditorModel+Capture.swift`.
**Learning:** Swift's strict memory safety means force unwrapping nil values results in a runtime crash, creating a vector for application instability and potential Denial of Service (DoS) vulnerabilities.
**Prevention:** Avoid force-unwrapping (`!`) entirely. Use safe optional binding (`if let`, `guard let`), optional chaining (`?.`), nil-coalescing (`??`), or local variable restructuring to safely access values.

## 2026-07-11 — Avoid Force Unwraps in AudioPublishBridge
**Vulnerability:** Found a force unwrap (`!`) when accessing `baseAddress` from a buffer pointer in `AudioPublishBridge.swift`.
**Learning:** Force-unwrapping poses a Denial of Service (crash) risk in Swift. If the buffer is empty or uninitialized, `baseAddress` will be nil, and the force unwrap will crash the application.
**Prevention:** Always use safe optional binding (`if let`) when dealing with optional variables, especially pointers to memory buffers.

## 2026-07-13 - Prevent unencrypted stream key transmission
**Vulnerability:** WHIP client allowed publishing stream keys (Bearer tokens) over unencrypted HTTP connections.
**Learning:** Network clients must explicitly validate that sensitive credentials are only transmitted over secure channels (HTTPS) or local loopback interfaces. Unencrypted transmission exposes stream keys to interception on the network path.
**Prevention:** Always assert the protocol scheme is `https` (or target is `localhost` for local dev tools) before attaching authentication headers to outgoing HTTP requests.

## 2026-07-20 - Insecure Keychain Item Synchronization
**Vulnerability:** The application was using `kSecAttrAccessibleWhenUnlocked` to store credentials in the macOS Keychain. This configuration allows sensitive items to sync across devices via iCloud Keychain.
**Learning:** For application-specific sensitive credentials (like stream keys or specific API tokens), syncing them across iCloud to other devices or migrating them can unnecessarily expand the attack surface.
**Prevention:** Always use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` when saving sensitive credentials to the Keychain to ensure they remain bound to the device where they were created and do not sync to iCloud Keychain.
