# Roadmap to parity with browser-editor v1

LocalCut Studio is the native macOS port of [browser-editor](https://github.com/shenghaoc/browser-editor), which has reached **v1.0.0**. This document plans the path from our current **v0.1.0** (Phase 1 foundation) to a parity **v1.0.0** native release.

The plan splits the upstream roadmap by ML dependency. macOS 27 is still in beta at the time of writing, and [Apple's on-device Core AI stack](https://developer.apple.com/core-ai/) (Foundation Models, Translation, Speech, Vision) — which supersedes the older Core ML framework — requires macOS 27. The non-ML phases ship on **`main`** (CI on GitHub Actions' macOS-26 runners). The ML-backed phases proceed on the **`next`** branch targeting macOS 27, validated locally on a macOS 27 / Xcode 27 host until Actions ships a macOS 27 image, at which point `next` merges into `main`.

> **Versioning note.** Apple jumped the marketing version from macOS 15 (Sequoia, 2024) to **macOS 26** (Tahoe, 2025), aligning every Apple OS marketing number with its calendar year (iOS 26, watchOS 26, etc.). macOS 27 is the 2026 release — currently in beta. The non-sequential gap between 15 and 26 is real, not a typo. `MACOSX_DEPLOYMENT_TARGET = 26.0` in `LocalCut Studio.xcodeproj` corresponds to Apple's 2025 marketing version, and `VTFrameProcessor` referenced in Phase 37 is the API introduced in macOS 15.4 (still the live API on macOS 26+).

## Version path

### v0.1.x → v0.2.0 — Non-ML phases (in order)

Each completed phase bumps **MARKETING_VERSION** by `0.0.1`; the final phase ships as `v0.2.0`.

| Tag | Phase | Spec | Theme |
|---|---|---|---|
| v0.1.1 | 30 | [phase-30-animated-captions](./phase-30-animated-captions/) | Animated caption styles (花字) |
| v0.1.2 | 32a | [phase-32a-skin-smoothing](./phase-32a-skin-smoothing/) | Core Image skin smoothing (磨皮, no ML) |
| v0.1.3 | 34 | [phase-34-beat-tools](./phase-34-beat-tools/) | Beat detection and beat-synced editing (卡点) |
| v0.1.4 | 35 | [phase-35-speed-ramps](./phase-35-speed-ramps/) | Speed ramps + pitch-preserving time-stretch |
| v0.1.5 | 36 | [phase-36-voice-cleanup](./phase-36-voice-cleanup/) | Voice cleanup (denoise, R128 loudness, gate/limiter) |
| v0.1.6 | 38 | [phase-38-look-packs](./phase-38-look-packs/) | Look packs + animated overlays |
| v0.1.7 | 39 | [phase-39-vertical-finishing](./phase-39-vertical-finishing/) | Vertical-first finishing (9:16/1:1/4:5, safe zones, covers) |
| v0.1.8 | 41 | [phase-41-capture-engine](./phase-41-capture-engine/) | ScreenCaptureKit + AVCaptureSession capture engine |
| v0.1.9 | 42 | [phase-42-recorder-ux](./phase-42-recorder-ux/) | Recorder UX (countdown, pause/resume, PiP control) |
| v0.1.10 | 43 | [phase-43-screencast-look](./phase-43-screencast-look/) | Zoom-n-pan, callouts, padded background |
| v0.1.11 | 44 | [phase-44-tutorial-finishing](./phase-44-tutorial-finishing/) | Silence detection, keystroke overlays, chapter export |
| v0.1.12 | 45 | [phase-45-program-mode](./phase-45-program-mode/) | Live scene mixing with ISO recording |
| v0.1.13 | 46 | [phase-46-replay-buffer](./phase-46-replay-buffer/) | Replay buffer + live audio chain |
| v0.1.14 | 47 | [phase-47-whip-publish](./phase-47-whip-publish/) | WHIP publish (RFC 9725) |
| **v0.2.0** | 48 | [phase-48-otio-interchange](./phase-48-otio-interchange/) | OpenTimelineIO export + CMX3600 EDL |

### v0.2.x → v1.0.0 — ML phases (Core AI on macOS 27, `next` branch)

Each completed phase bumps **MARKETING_VERSION** by `0.0.1`; the final phase ships as `v1.0.0` — parity with browser-editor v1. These phases are developed on the **`next`** branch targeting macOS 27. CI is disabled for `next` (GitHub Actions runners are macOS-26-only); validation runs locally on a macOS 27 / Xcode 27 host. When macOS 27 leaves beta and Actions ships a macOS 27 image, `next` merges into `main`.

Order follows the upstream recommendation (29 → 31 → 33 → 32b → 37, with 40 last so the v1.0.0 cut is the language pack).

| Tag | Phase | Spec | Theme |
|---|---|---|---|
| v0.2.1 | 29 | [phase-29-auto-captions](./phase-29-auto-captions/) | On-device auto captions (Speech framework) |
| v0.2.2 | 31 | [phase-31-portrait-matting](./phase-31-portrait-matting/) | Portrait video matting (Vision person segmentation) |
| v0.2.3 | 33 | [phase-33-smart-reframe](./phase-33-smart-reframe/) | Smart reframe (Vision face/saliency + tracker) |
| v0.2.4 | 32b | [phase-32b-landmark-beauty](./phase-32b-landmark-beauty/) | Landmark-driven beauty (瘦脸 / 大眼) |
| v0.2.5 | 37 | [phase-37-frame-interpolation](./phase-37-frame-interpolation/) | Frame interpolation via VTFrameProcessor (no model vendoring) |
| **v1.0.0** | 40 | [phase-40-language-tools](./phase-40-language-tools/) | On-device language tools (Foundation Models, Translation) |

## Prerequisite infrastructure (interleaved through v0.1.x)

These currently-proposed feature specs are **prerequisites** for many of the phases above; they land in the 0.1.x series alongside the new phases as dependencies require, but do not consume their own version slots in the table — the prompts assumed this infra exists upstream and we have to build it.

| Existing spec | Provides | Phases that need it |
|---|---|---|
| [feature-colour-grading](./feature-colour-grading/) | Custom `AVVideoCompositing` with per-clip effect chain | 32a, 38 |
| [feature-timeline-trim-and-drag](./feature-timeline-trim-and-drag/) | Direct-manipulation clip editing | most |
| [feature-transitions](./feature-transitions/) | Cross-dissolve / wipe primitives | 38, 45 |
| [feature-project-persistence](./feature-project-persistence/) | Codable ProjectDoc + security-scoped bookmarks + undo | 30, 38, 39, 44, 48 |
| [feature-keyframes](./feature-keyframes/) | `Keyframed<T>` + `Interpolatable` + binary-search evaluator | 30, 32a, 35, 38, 43 |
| [feature-caption-tracks](./feature-caption-tracks/) | `CaptionTrack` model + SRT/VTT importers + persistence | 30, 44 |
| [feature-title-raster](./feature-title-raster/) | Core Text rasteriser with LRU cache | 30, 38 |
| [feature-export-queue](./feature-export-queue/) | `ExportPreset` + serial `RenderQueue` on top of `AVAssetExportSession` / `AVAssetWriter` | 39 |
| [feature-colour-management](./feature-colour-management/) | Working-space tagged pixel buffers + waveform/vectorscope overlay | 38 |
| [feature-markers](./feature-markers/) | `TimelineMarker` model + ruler rendering + add/remove/keyboard | 34, 44 |
| [feature-diagnostics](./feature-diagnostics/) | Single-pane perf/probe panel (CPU, GPU est., decoders, render-time p95, drops) | 37, 41, 46 |
| [feature-render-cache](./feature-render-cache/) | Post-effect-chain `CIImage` cache keyed on (clip id, effect chain hash, time, render size) under Caches/ | 35, 37 |
| [feature-capability-tiers](./feature-capability-tiers/) | Chip / memory / encoder probe → `baseline` / `accelerated` / `pro` verdicts | 37, 41, 45 |
| [feature-audio-master-bus](./feature-audio-master-bus/) | `AVAudioEngine` master bus (live + offline graphs), per-clip envelopes, meters | 35, 36, 46 |
| [feature-project-bundles](./feature-project-bundles/) | `.lcbundle` directory format with `project.json` + `assets/` + fingerprints | 30, 34, 38, 48 |

The following infrastructure was implied by browser phases referenced in the prompts (P10 markers, P14 GPU title raster, P15 keyframes, P16 audio buses, P17/24 export expansion, P19 proxy/render cache, P21 colour management, P22 caption tracks, P25 diagnostics, P26 capability tiers). P10 / P14 / P15 / P16 / P17/24 / P19 / P21 / P22 / P25 / P26 are now specced above. The rest are **not yet specced** for the native port and each spec calls out the ones it needs in its design `Prerequisites` section. Spec them as they become blocking; do not pre-spec speculatively.

## Why "Core AI on macOS 27" replaces the browser ML runtime

The browser prompts assume "Phase 28": a worker-owned inference runtime over `transformers.js` / `onnxruntime-web` with a WebGPU → WebNN → WASM ladder, OPFS-cached weights, and zero-copy `VideoFrame` ↔ tensor IO. The native port replaces all of this with Apple's stack:

| Browser ML runtime (P28) | Native macOS equivalent |
|---|---|
| transformers.js / onnxruntime-web | **Core AI** runtime + Foundation Models (macOS 27+) — Core AI is the umbrella that supersedes Core ML |
| WebGPU compute / WebNN | Neural Engine + Metal Performance Shaders Graph (Core AI selects compute units) |
| OPFS-cached weights + manifest | App container `Models/` with notarised manifest; many models bundled with the OS |
| Per-EP execution providers | Core AI compute-unit selection chosen by a probe |
| `VideoFrame` → external texture | `CVPixelBuffer` → Metal texture (zero-copy via IOSurface) |
| Origin trial token gating | OS version + chip family + Foundation Models availability check |
| Model download size UX | Bundled or on-demand Core AI model with progress on first use |

The ML phases (29, 31, 32b, 33, 37, 40) each name the specific Apple framework or Core AI model they target. Phase 40 is the only one that depends on **Foundation Models** (`com.apple.foundationmodels`) being publicly available; the others use Vision / Speech / Core AI / VideoToolbox which are mature on macOS 26 but get materially better APIs and on-device models on macOS 27. These phases proceed on the **`next`** branch so development can begin now; they will merge to `main` once macOS 27 is GA and every ML feature shares one minimum-OS baseline.

Note on Phase 37: VideoToolbox's `VTFrameProcessor` (macOS 15.4+) ships native frame interpolation, frame-rate conversion, optical flow, and motion blur on the Neural Engine — Phase 37 uses it directly rather than vendoring a Core AI port of RIFE.

## Third-party dependencies

The roadmap introduces exactly **two** non-Apple runtime libraries; both are justified in-place in the spec that introduces them:

| Library | Phase | Why it can't be Apple-native |
|---|---|---|
| [`lottie-ios`](https://github.com/airbnb/lottie-ios) (Apache-2.0) | [Phase 38](./phase-38-look-packs/) | Lottie's After Effects JSON model has no Apple equivalent — `CAEmitterLayer` / `CAAnimation` / SwiftUI animation cover nothing of it. Writing a renderer from scratch would dwarf the spec. |
| Community WebRTC XCFramework — primary [`stasel/WebRTC`](https://github.com/stasel/WebRTC); fallback [`webrtc-sdk/webrtc`](https://github.com/webrtc-sdk/webrtc) (BSD-3-Clause) | [Phase 47](./phase-47-whip-publish/) | Apple ships WebRTC inside `WKWebView` only; it is not exposed as a standalone framework usable from AppKit / SwiftUI. WHIP requires `RTCPeerConnection`. The official GoogleWebRTC CocoaPods binary is iOS-only with no macOS slice — adding it via SPM would not link the macOS target. The community packages repackage upstream `webrtc.googlesource.com` sources with the public API unchanged. |

Every other ML / media path uses an Apple-provided API — no vendored on-device models anywhere in the roadmap.

## Apple API spot-checks

API symbols cited in the specs were spot-checked against Apple's documentation as of June 2026:

- **`SystemLanguageModel.default.availability`** + **`LanguageModelSession.respond(to:)`** (Foundation Models, macOS 26+) — verified against WWDC25 §286.
- **`LanguageAvailability.status(from:to:)`** (Translation framework) + SwiftUI **`.translationTask(_:)`** — verified against framework reference.
- **`SFSpeechRecognizer(locale:).supportsOnDeviceRecognition`** — instance property, depends on locale; gate must be re-run when language changes.
- **`VNGeneratePersonSegmentationRequest`** / **`VNDetectFaceLandmarksRequest`** (returns `[VNFaceObservation]` with `landmarks: VNFaceLandmarks2D?` — detection + landmarks in one pass) / **`VNDetectFaceRectanglesRequest`** / **`VNGenerateAttentionBasedSaliencyImageRequest`** — Vision framework, all current.
- **`VTFrameProcessor`** (class, macOS 15.4+ / Mac Catalyst 26+ / iOS / iPadOS / tvOS / visionOS 26+) — lifecycle is `init()` → `startSession(configuration:) throws` → `process(with: MTLCommandBuffer, parameters:)` (the Metal variant; async-sequence and completion-handler variants also exist) → `endSession()`. Configurations conform to `VTFrameProcessorConfiguration`: `VTLowLatencyFrameInterpolationConfiguration`, `VTFrameRateConversionConfiguration`, `VTOpticalFlowConfiguration`, `VTMotionBlurConfiguration`. Frames cross as `VTFrameProcessorFrame` / `VTFrameProcessorFrame.ReadOnlyFrame`. Configurations cannot be swapped on a live processor; create one processor per use case.
- **`AVAudioInputNode.setVoiceProcessingEnabled(_:)`** — real-time-rendering only; refuses `manualRenderingMode = .offline` (WWDC19 §510). Phase 36 splits live + offline graphs as a consequence.
- **`AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)`** — per-track, shifts every clip after it on the same track; build order matters or isolate to a dedicated track.
- **`AVMutableAudioMixInputParameters.audioTimePitchAlgorithm`** — per-input-parameters, NOT on `AVMutableAudioMix`.
- **`AVAssetWriter.movieFragmentInterval`** — the property that creates a fragmented `.mov` readable up to the last flushed fragment.
- **`SCStreamConfiguration.capturesAudio = true`** (ScreenCaptureKit, macOS 13+) for system audio.
- **`CMClockGetHostTimeClock()`** for shared capture timing — PTS are ns-since-boot; must be normalised by subtracting a `sessionStartHostTime` snapshot.
- **`NSEvent.addLocalMonitorForEvents(matching:handler:)`** for Phase 43's own-process event log — does not require Accessibility permission (cross-app via `CGEventTap` would, and is out of scope).
- **`FileManager.url(for: .cachesDirectory, in: .userDomainMask, ...)`** for Phase 46's spill — App Sandbox grants the container Caches directly; no security-scoped bookmark needed.

If a symbol resolves differently when Xcode is opened, update the spec rather than working around the discrepancy.

## Source-of-truth note

The canonical source for each phase's intent is the **shipped** spec in the upstream [browser-editor](https://github.com/shenghaoc/browser-editor) repo's `.kiro/specs/phase-NN-*/`. When implementing a phase here, cross-reference the upstream `design.md` for concrete decisions (model choice + provenance, parameter ranges, container formats, exact heuristics) — the macOS specs in this folder paraphrase those decisions for the AVFoundation / Metal / Core AI stack but do not duplicate every tuning constant.

| Phase | macOS spec drafted from |
|---|---|
| 29, 31, 33, 37, 45, 47, 48 | The shipped upstream `design.md` (verified at draft time). |
| 30, 32a, 34, 35, 36, 38, 39, 41, 42, 43, 44 | The planning prompts the user supplied; upstream `design.md`s should be consulted before implementing to catch any drift between prompt and shipped behaviour. |
| 32b, 40, 46 | A summarised reading of the upstream `design.md`. Re-fetch the full upstream `design.md` before implementing for exact tunables. |

If an upstream spec changes meaningfully (e.g. a bugfix folder amends the design), update the corresponding macOS spec to match.

## How to use this roadmap

1. Pick the next row in the appropriate table.
2. Read the corresponding spec folder (`design.md`, `requirements.md`, `tasks.md`).
3. Cross-reference the upstream browser-editor spec for concrete tuning + decisions (see source-of-truth note above).
4. Confirm the spec's `Prerequisites` are met; if not, spec or build the missing infra first.
5. Implement; gate the PR through `xcodebuild` + the [review policy](../steering/review.md) + [release-readiness checklist](../../RELEASE-READINESS.md).
6. On merge, bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` and tag the release.

Phase numbering preserves the upstream browser-editor numbering so the relationship between the two codebases stays legible. Gaps (e.g. no Phase 28 spec here, no Phase 13 spec) are intentional and explained above.
