# Testing Standards

## Framework & environment

- **Runner**: Swift Testing (`import Testing`, `@Test`, `#expect`) for unit tests; **XCUIAutomation** for UI tests. Do not add XCTest-based unit tests for new code.
- **Location**: a `LocalCut StudioTests` target alongside the app target (added when the first non-trivial pure-logic unit lands).
- **Scope**: deterministic, framework-light logic — timeline model math and the parts of `CompositionBuilder` that don't require decoding real media.
- **Cross-platform gate**: `LocalCutDomainTests` must pass with SwiftPM on
  Linux. `LocalCutCoreTests` run on macOS; `LocalCutPlatform` is built by SwiftPM
  and its binary-framework behavior is exercised by the Xcode suite.

## What to test

| Target | Requirement |
|--------|-------------|
| Timeline mutations | `addToTimeline`, `splitSelectedClipAtPlayhead`, `deleteSelectedClip`, `updateSelectedClip` — start/duration/source-offset correctness, edge cases (split at boundary, empty track, single-frame clip). |
| `Project` time math | `Track.endTime`, `Project.duration` across gaps and multiple tracks. |
| Fit transform | `CompositionBuilder.fitTransform` — aspect-fit scale + centering for landscape/portrait/rotated `preferredTransform`. |
| Instruction segmentation | Boundary collection produces non-overlapping, gap-correct instruction ranges for overlapping multi-track layouts. |
| Time formatting | `TimeFormatting.timecode` rounding and clamping. |

Any non-trivial logic change **must** ship with tests; the test count must not decrease from the last green run.

## How to test AVFoundation logic without real media

- Factor pure math (transforms, boundary segmentation, time arithmetic) out of methods that touch `AVAsset`, and test the pure parts directly.
- For composition assembly, build from short generated assets (e.g. `AVAssetWriter` color-bar clips or bundled fixtures) rather than asserting on decoded pixels.
- Mock at the boundary; do not mock `CMTime` or the model types under test.

## What not to test

- Pixel-exact render output (GPU/Core Image) — validate visually or via the integration smoke test.
- SwiftUI view internals — test observable behaviour through the model, not view wiring.
- `AVPlayer` playback timing — covered by manual smoke testing.

## Integration smoke test (manual)

1. `BuildProject` → `RunProject`; the window opens with empty bin/preview/timeline.
2. Import a local MP4/MOV → it appears in the bin with a thumbnail.
3. Double-click to add → clip lands on the timeline; preview shows it.
4. Scrub, play/pause, split at playhead, delete; adjust opacity.
5. Export to `.mov` → progress advances → the file plays back correctly.

## Native document lifecycle manual check

Run this checklist whenever document/window shell code changes. These are GUI
behaviours; do not claim them as unit-test coverage.

1. Create a new project, import local media, and save as `.lcbundle`.
2. Close, reopen the bundle, and verify media, edits, dirty title state, and
   undo/redo survive.
3. Make an edit, then close and exercise **Save**, **Don't Save**, and
   **Cancel**. A failed save must leave the window open and dirty.
4. Verify Open, Open Recent, Save As between allowed `.lcstudio` / `.lcbundle`
   forms, missing-media relinking, and external bundle-change warning behaviour.
5. Invoke an App Intent with one active window and confirm it reaches that
   editor. Before a window appears, verify the intent reports the typed
   no-active-document condition rather than mutating an arbitrary model.
6. The current macOS 26 custom-controller architecture does **not** present
   independent document scenes, so opening two GUI documents is not applicable.
   The registry's two-editor routing is covered by deterministic tests instead.
7. Start recording, then try New, Open, and Close; all document replacement / close
   paths must remain blocked until recording is safely finished.
8. Queue a video render, choose a new output destination, and verify output access
   remains valid through queue execution/retry.
9. In marker names, captions, and inspector fields, press Space, M, Shift-M, and
   Delete. Text editing and a keyboard-focused button/toggle must keep their
   native key behaviour; timeline shortcuts must only act after the timeline is
   focused.
10. Check a fresh window on a normal and constrained display, then relaunch to
    verify macOS restoration and split-view divider persistence. Collapse and
    re-expand the inspector to ensure its saved expanded width is not clobbered.

## Quality gate

`swift test --package-path Packages/LocalCutCore` must pass on macOS and Linux
for the targets available on each host. `xcodebuild` (Debug,
macOS) must compile cleanly and the test suite must stay green with no count
regression before merging any non-trivial logic change.
