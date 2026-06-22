# Palette — Accessibility & UI Journal

Append a dated entry whenever you learn something about LocalCut Studio's accessibility or native UI fit (VoiceOver, keyboard, Dynamic Type, contrast, macOS conventions). Format: **Learning** + **Action**.

## 2026-06-21 — Icon-only controls need labels, not just tooltips

**Learning:** The toolbar, transport, bin "+", and timeline zoom glyphs are icon-only. `.help(...)` adds a hover tooltip but does **not** expose a VoiceOver label, so screen-reader users hear "button" with no meaning.
**Action:** Pair every icon-only control with both `.help(...)` and an explicit accessibility label (`Label("Split", systemImage: "scissors")` or `.accessibilityLabel("Split clip at playhead")`). Audit with the `accessibility-voiceover-specialist` skill before merging UI.

## 2026-06-21 — Timeline clips must be reachable and stateful to VoiceOver

**Learning:** Clip blocks are custom-drawn `RoundedRectangle`s positioned by time; by default they're decorative to assistive tech, and selection is conveyed by border colour alone.
**Action:** Give each clip an `accessibilityLabel` of media name + start + duration, add `.isSelected` trait when selected, and pair the selection colour with the border so state isn't colour-only.

## 2026-06-21 — Custom layout sliders need explicit accessibility labels

**Learning:** In SwiftUI, when a `Slider` is placed adjacent to a `Text` label in a custom layout (like `VStack`), VoiceOver treats them as separate elements. The user navigates to the slider and hears a generic "slider" announcement without knowing what it controls — and if the `Text` mirrors the value, the same information is announced twice (once for the `Text`, once for the slider).
**Action:** Add an `.accessibilityLabel` directly to the `Slider` (with `.accessibilityValue` when the displayed format deviates from the default), and hide the now-redundant visual `Text` with `.accessibilityHidden(true)` so it isn't announced twice. Spell out abbreviated visual labels (e.g. "Temp offset" → "Temperature Offset") for the spoken label.
## 2026-06-22 — Custom layout sliders in Beauty section lack accessibility labels

**Learning:** Similar to other custom layout sliders, the Strength, Mask Warmth, and Luminance Gate sliders in the Beauty section of the Inspector announced generic values and had redundant visual text read by VoiceOver.
**Action:** Hid the visual labels with `.accessibilityHidden(true)` and added `.accessibilityValue` to the sliders directly to ensure a clean VoiceOver experience, matching the existing accessible slider pattern.
