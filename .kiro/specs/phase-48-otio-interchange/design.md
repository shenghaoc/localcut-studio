# Design: Phase 48 — OpenTimelineIO Export

> Status: **Proposed**. Target tag: **v0.2.0** (final non-ML phase; promoted from a patch bump to a minor release).

## Goal

A pure-Swift serialiser from `ProjectDoc` to `.otio` (OpenTimelineIO's serialised form is documented JSON — no Python, no native bindings) covering tracks, clips with source references carrying file-fingerprint metadata, markers, and transitions mapped to OTIO's standard transition kinds. Everything LocalCut-specific (effects, looks, layout tracks, caption styling) nests under a `metadata.localcut` namespace so foreign tools ignore it and LocalCut can round-trip it later. A cuts-only CMX3600 EDL falls out of the same time model for free. The `.otio` lands in the project bundle root alongside `project.json` (`project.json` stays authoritative). Importing is a follow-up phase.

The browser-editor's implementation is hand-rolled TypeScript with no runtime deps — we mirror it exactly in Swift.

## Prerequisites

- `feature-project-persistence` (the `ProjectDoc` codable structure that the serialiser reads + the project bundle that writes `project.otio` alongside `project.json`).
- Timeline markers (not yet specced) for the `Marker.2` emit path.
- Phase 38 LUTs (for `lut` metadata; emitted by `key + fileName` only — never texture data).
- Phase 30 caption tracks (emitted under `Timeline.metadata.localcut.captionTracks`; OTIO has no portable caption schema).

## Approach

1. **Time model.** One module owns rate + snap-to-frame. `interchangeRate(doc)` picks `exportSettings.fps` if finite > 0, else the most common source video frame rate, else 30. Snap each timeline boundary independently (clip starts / ends, marker times, transition cut points) and derive each item's duration as `endFrames − startFrames`. Two adjacent clips stay adjacent in frames; rounding can shift a cut by half a frame but cannot open a gap or create an overlap. Clips collapsing to zero frames are dropped (with a warning); transitions without an adjacent pair are dropped (with a warning). Fractional rates (23.976, 29.97) keep exact rational representation.
2. **Schema allowlist.** Emit only `Timeline.1`, `Stack.1`, `Track.1`, `Clip.2`, `Gap.1`, `Transition.1`, `Marker.2`, `ExternalReference.1`, `GeneratorReference.1`, `MissingReference.1`, `RationalTime.1`, `TimeRange.1`. `Clip.2` (media-references map + active key) is what current Kdenlive / Resolve consume.
3. **Mapping table.**
   | LocalCut | OTIO | Notes |
   |---|---|---|
   | `ProjectDoc` | `Timeline.1` | name = display name; `global_start_time` 0 |
   | `TimelineTrack` | `Track.1` kind `Video` / `Audio` | mix state in `metadata.localcut` |
   | gap | `Gap.1` | from project gap model |
   | `Clip` (source) | `Clip.2` + `ExternalReference.1` | source range from `inPoint` / `duration` |
   | `Clip` (title) | `Clip.2` + `GeneratorReference.1` | `generator_kind: "localcut.title"` |
   | missing source | `Clip.2` + `MissingReference.1` | original file name + sourceId preserved |
   | `TimelineMarker` | `Marker.2` on the `Stack` | zero-duration; default `PURPLE` |
   | `TimelineTransition` | `Transition.1` | total duration snapped; `in/out_offset` floor/round; cross-dissolve → `SMPTE_Dissolve`, others → `Custom_Transition` |
   | effects / transform / keyframes / LUT ref / fades | `Clip.metadata.localcut` | LUT by `key` + `fileName` only |
   | caption tracks + styling | `Timeline.metadata.localcut.captionTracks` | OTIO has no portable caption schema |
   | media fingerprint | `ExternalReference.metadata.localcut.fingerprint` | content identity for future re-linking |
4. **Determinism.** The serialiser is a pure function of `ProjectDoc` (plus an options record). It reads `doc.savedAt` for any timestamp, generates no IDs, emits via `JSONEncoder` with `.sortedKeys + .prettyPrinted` over objects built in fixed key order. Goldens compare byte-for-byte.
5. **CMX3600 EDL.** Single video track per list (CMX3600 is structurally single-track). Record TC starts at `01:00:00:00`. Frame rate is `round(rate)` non-drop; fractional rates add a `* LOCALCUT: RATE 29.97 ROUNDED TO 30 NDF` comment. Reel names are uppercase-alphanumeric from the file-name stem (max 8 chars including dedup suffix); titles use reel `AX`. Transitions on the exported track become straight cuts at the cut point with a warning per omission.
6. **Bundle integration.** `exportProjectBundle` writes `project.otio` to the bundle root after `project.json`. The serialiser takes a `resolveTargetUrl(sourceId): String` closure; bundle export supplies fingerprint-derived `media/…` paths; standalone export supplies original file names. Serialisation failure becomes a warning-severity bundle integrity item; bundle export still succeeds.
7. **Worker boundary.** Generation is synchronous string building over the in-memory model (KB-scale output); runs on a background actor for consistency but doesn't need to.

## Trade-offs

- Hand-rolled emitter over a third-party library: OTIO has no first-party Swift binding, and the upstream OTIO is Python/C++ (exactly the dependency we're avoiding). The emitter is ~600 lines of Swift.
- `Clip.2` (media-references map) over `Clip.1` (single reference): the newer schema is what current Kdenlive / Resolve consume; readers built on pre-0.15 OTIO are out of scope.
- CI uses Python `opentimelineio` to parse goldens against the reference implementation — never shipped, never required locally.

## Risks

- OTIO schemas evolve; we pin to current Kdenlive 25.04+ and DaVinci Resolve behaviour and document the verification checklist for both.
- LocalCut features whose metadata foreign tools cannot interpret travel as opaque metadata; round-trip parity depends on a future Phase 48b import path.

## Non-goals

- OTIO import (follow-up phase).
- AAF / FCPXML in-app — documented via the `otioconvert` path.
- Translating effects between applications.
- Audio events or dissolves in the EDL — cuts-only freebie.
- Embedding media bytes in the `.otio` — references only.
- General-purpose OTIO library.
