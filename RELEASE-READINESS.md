# Release Readiness

Gate checklist before tagging a release. Pair with [`BLOCKER-CLASSIFICATION.md`](BLOCKER-CLASSIFICATION.md) (no open P0/P1) and the per-PR [`A11Y-CHECKLIST.md`](A11Y-CHECKLIST.md).

## Build & quality

- [ ] `xcodebuild` (Release, macOS) builds cleanly with no new warnings
- [ ] Test suite green; test count not regressed
- [ ] No open **P0** or **P1** issues
- [ ] No dead code, no leaked resources (security scopes, observers, `Task`s) in changed areas

## Functionality (smoke)

- [ ] Import MP4/MOV/audio → appears in bin with thumbnail
- [ ] Add to timeline, scrub, play/pause, split, delete
- [ ] Per-clip adjustments reflect in preview without losing playhead
- [ ] Export `.mov` completes with progress and plays back correctly
- [ ] Preview and exported output match for every shipped effect/transition

## Robustness

- [ ] Unsupported/corrupt media fails gracefully with a user-visible message
- [ ] Cancelling an export leaves no partial file at the user's path
- [ ] Reopening a saved project re-resolves media (once persistence ships); missing media offers relink

## Platform fit

- [ ] App Sandbox on; only the entitlements actually used are present
- [ ] Light/dark both correct; VoiceOver pass on primary flows; key shortcuts work
- [ ] App name shows "LocalCut Studio" in menu bar, Finder, and About

## Release hygiene

- [ ] Version/build numbers bumped (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)
- [ ] `docs/` updated for user-facing changes; shortcuts reference current
- [ ] README status section reflects what shipped
- [ ] Tag created; release notes summarize completed specs
