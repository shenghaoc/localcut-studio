# Code Style

## Swift

- **Swift 6 concurrency** — the target defaults to `MainActor` isolation. Keep UI/model types on the main actor; move heavy media work off it explicitly (`Task.detached` or a dedicated actor) only when it measurably blocks. Mark escaping closures' captures `[weak self]`.
- **Observation, not Combine** — model state is `@Observable`; views use `@State`/`@Bindable`. Use `async`/`await` and `AsyncSequence` (e.g. `AVAssetExportSession.states(updateInterval:)`) instead of publishers.
- **`@ObservationIgnored` requires a reason** — every `@ObservationIgnored` annotation on `EditorModel` must be justifiable (see the policy table in that file's header doc). Categories: static/constant, injected store, service/coordinator objects, framework objects, observer/notification handles, task handles, stale-cancellation tokens, security-scoped cleanup, caches/memoisation, undo coalescing plumbing, capture/recorder internal state, document/operation guards. When adding a new ignored property, classify it in the header table.
- **No force unwrap / force try** on anything derived from user media. Use `guard let`, `try?` with a user-visible fallback, or surface the error to `statusMessage`.
- **Value types for data, reference types for identity/lifecycle** — `Clip` is a `struct`; `Track`/`Project`/`MediaItem`/`EditorModel` are `@Observable` classes.
- **Immutability** — prefer `let`; mutate model arrays in place through the owning object so Observation fires.

## CoreMedia / AVFoundation

- All editing math in `CMTime` / `CMTimeRange`; convert to `Double` seconds only at the UI boundary (pixels ↔ time). Construct times with timescale `600`.
- Every `AVAssetImageGenerator` is created for a batch and released after; never one-per-frame in a hot path.
- Balance every `startAccessingSecurityScopedResource()` with a `stop` on the matching lifetime.
- Remove periodic time observers in `deinit`; cancel `Task`s you own.

## SwiftUI

- One primary `View` per file; break large bodies into `private` computed properties or small subviews, not giant `body`s.
- Drive dynamic layout with `frame`/`layoutPriority`/`Spacer`, not magic offsets — except timeline clip positioning where `offset(x:)`/`width` encode time.
- Bindings that trigger expensive work (rebuilds) should debounce or coalesce; don't rebuild the whole composition on every slider tick.

## Naming

| Kind | Convention |
|------|-----------|
| Types | `PascalCase` |
| Properties, methods, cases | `camelCase` |
| Views | `XxxView` |
| Booleans | `is`/`has`/`should` prefix (`isPlaying`, `hasAudio`) |

## Comments

Write comments only when the **why** is non-obvious — a CoreMedia coordinate quirk, an AVFoundation ordering requirement, a concurrency invariant. Don't narrate what well-named code already says. Don't reference the current task or issue number in source.

## Formatting

- 4-space indentation; follow the surrounding file.
- Keep imports minimal and at the top (`SwiftUI`, `AVFoundation`, `AVKit`, `CoreMedia`, `UniformTypeIdentifiers`).
- Match the existing file's comment density and idiom; do not reformat unrelated code in a feature PR.
