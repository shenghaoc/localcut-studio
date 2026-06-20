# Testing Standards

## Framework & environment

- **Runner**: Swift Testing (`import Testing`, `@Test`, `#expect`) for unit tests; **XCUIAutomation** for UI tests. Do not add XCTest-based unit tests for new code.
- **Location**: a `LocalCut StudioTests` target alongside the app target (added when the first non-trivial pure-logic unit lands).
- **Scope**: deterministic, framework-light logic — timeline model math and the parts of `CompositionBuilder` that don't require decoding real media.

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

## Quality gate

`xcodebuild` (Debug, macOS) must compile cleanly and the test suite must stay green with no count regression before merging any non-trivial logic change.
