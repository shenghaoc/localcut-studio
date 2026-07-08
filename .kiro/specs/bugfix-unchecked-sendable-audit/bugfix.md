# Bugfix: `@unchecked Sendable` Audit

> Status: **Complete**. Tracked by GitHub PR #79.

PR #79 audits every production `@unchecked Sendable` conformance and documents
the synchronization or confinement contract that makes each conformance safe.
The branch is intentionally narrow: it does not change the media pipeline, app
actor model, export behavior, capture behavior, or project persistence schema.

## Bugs

### B1 - Production `@unchecked Sendable` conformances were undocumented

Several framework-facing or thread-hopping helper types used
`@unchecked Sendable` without an adjacent explanation of the safety invariant.
That made future review work harder because reviewers had to rediscover whether
the type was lock-protected, queue-confined, immutable, or required by a
framework protocol.

- **Fix**: Add direct comments to every production conformance that name the
  protected state and the synchronization or confinement boundary.
- **Impact**: No product behavior change. The comments make the Swift 6
  concurrency escape hatches auditable.

### B2 - Program compositor scene reads bypassed the state lock

`ProgramCompositor.currentScene` was exposed with `private(set)`, so tests and
future callers could read scene state without using the same lock that protects
scene writes.

- **Fix**: Make `currentScene` private and expose `activeScene` as a
  lock-protected read-only accessor.
- **Impact**: No compositor behavior change. Tests keep their visibility into
  the current scene without bypassing synchronization.

### B3 - Non-WebRTC video tap latest-frame reads should use the shared lock

The non-WebRTC fallback keeps a latest-frame test seam. Main already converted
that seam to private storage plus a computed getter; this branch keeps the same
API and uses `NSLock.withLock` for the read.

- **Fix**: Keep `latestPixelBuffer` as the test-facing accessor and read the
  backing storage through `lock.withLock`.
- **Impact**: No product behavior change. The non-WebRTC stub path remains
  deterministic and synchronized.

## Non-goals

- Do not broaden this PR into the separate `nonisolated(unsafe)` audit from
  PR #78.
- Do not remove conformances when the conformance is still required by
  framework protocols or cross-executor transfer.
- Do not refactor capture, publish, render-cache, overlay, or replay-buffer
  architecture.
- Do not change fixture generation or CI flake handling.
