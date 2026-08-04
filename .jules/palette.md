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

## 2026-06-22 — Beauty section sliders lack accessibility values and have redundant visible text labels

**Learning:** Similar to other custom layout sliders, the Strength, Mask Warmth, and Luminance Gate sliders in the Beauty section of the Inspector announced generic values and had redundant visual text read by VoiceOver.
**Action:** Hid the visual labels with `.accessibilityHidden(true)` and added `.accessibilityValue` to the sliders directly to ensure a clean VoiceOver experience, matching the existing accessible slider pattern.
## 2026-06-23 — Add Call to Action to Empty State
**Learning:** Empty states without a clear, prominent Call to Action (CTA) button force the user to hunt for the standard UI control (like a small `+` in a header toolbar) to proceed. In `MediaBinView`, the `ContentUnavailableView` instructed the user to import media but lacked a button to do so.
**Action:** Whenever using `ContentUnavailableView` or any empty state screen, leverage the `actions` parameter to include a prominent `Button` that directly initiates the primary action needed to populate the view.
## 2026-06-25 — Replace Plain Text Empty States with ContentUnavailableView
**Learning:** Using simple `Text` elements for empty states in inspector panels lacks affordance and feels like a dead end. Users shouldn't have to seek out buttons located elsewhere (like header controls) just to begin an interaction when an area is blank.
**Action:** Transition all plain text empty states to `ContentUnavailableView`, and leverage the `actions` parameter to include prominent buttons that map directly to the primary ways to populate that content (e.g., "Add at Playhead" for markers, "Import SRT/VTT" or "Add Empty Track" for captions).
## 2026-06-26 — Prevent Duplicate VoiceOver Reads on Sliders
**Learning:** Visual text labels (e.g. `HStack` with text and value) paired with `Slider`s in SwiftUI can cause VoiceOver to announce the label and value twice if the slider itself already sets `.accessibilityLabel` and `.accessibilityValue`.
**Action:** Always add `.accessibilityHidden(true)` to the visible text views when a neighboring accessible control already carries the full context.

## 2026-06-30 — Add Call to Action to Empty State in PreviewView
**Learning:** The 'No Preview' empty state in PreviewView only instructed users what to do but lacked a direct button to accomplish it. However, the CTA lives inside `videoCanvas` which uses `.accessibilityElement(children: .ignore)`, so VoiceOver cannot discover the button.
**Action:** Keep `videoCanvas` as the ignored, non-interactive preview surface and add the empty-state `ContentUnavailableView` as an overlay after that accessibility boundary. The 'Import Media…' CTA remains discoverable to VoiceOver while the parent "Preview" element still conveys the empty preview state. Scope `.foregroundStyle(.secondary)` to the title and description only — not the actions container — so the `.borderedProminent` button retains its default high-contrast label.
## 2026-07-04 — ContentUnavailableView is for full-pane empty states, not inline placeholders

**Learning:** `ContentUnavailableView` is designed for container-level or full-pane empty states where the entire view is unavailable. Using it inline within a `Form` `Section` alongside other active controls (buttons, toggles, sliders) violates macOS HIG — the large icon and title create an unbalanced visual hierarchy and look disproportionately large. Similarly, placing it at the top of a scrollable form when other sections remain active disrupts the layout.
**Action:** For inline placeholders within a section, use a simple `Text` view with `.foregroundStyle(.secondary)`. Reserve `ContentUnavailableView` for full-pane or container-level empty states (like an empty media bin or overlay list with no other sibling sections).

## 2026-07-10 — Add selection traits to custom checkmark lists

**Learning:** List items using custom selection indicators (such as a checkmark or background highlight) are announced poorly by VoiceOver unless the row also exposes its selection state. Screen readers may read a checkmark out of context or miss a background-only highlight entirely.
**Action:** Conditionally apply `.accessibilityAddTraits(.isSelected)` to the selectable control or row. For checkmark-based lists, also apply `.accessibilityHidden(true)` to the decorative checkmark so VoiceOver announces the selection state without reading the symbol.
## 2026-07-20 - Add missing labels to icon-only buttons in property editors
**Learning:** Buttons containing only `Label(..., systemImage: ...)` may still only render as icon-only in certain SwiftUI contexts and lack proper VoiceOver labels if the visual text is omitted or ignored by the view hierarchy. In `CaptionsInspectorView` and `ClipTransformKeyframeEditor`, the Add/Update keyframe buttons used a `Label` but were missing explicit `.accessibilityLabel(...)` and `.help(...)` modifiers compared to neighboring buttons.
**Action:** Always append explicit `.help(...)` and `.accessibilityLabel(...)` modifiers to any button functioning as an icon-only control, even if its content is a `Label` with text, to guarantee VoiceOver coverage and tooltips.
## 2026-07-18 - Tooltips for visually unlabeled controls
**Learning:** Icon-only controls or standalone Sliders (like the timeline zoom slider) that have an `.accessibilityLabel` for screen readers still leave pointer/mouse users guessing about their function if they lack a visual label.
**Action:** Always verify that interactive components without visible text labels include a `.help()` modifier to provide a tooltip for pointer users, even if an `.accessibilityLabel` is already present.
## 2026-07-19 — Apply .labelStyle(.iconOnly) to Label-based icon-only buttons

**Learning:** Buttons built with `Label(..., systemImage: ...)` in property editors that act as icon-only controls must explicitly use `.labelStyle(.iconOnly)`. This visually hides the text so they render strictly as icons, matching the design of sibling `Image` buttons, while preserving the text for VoiceOver screen readers.
**Action:** Add `.labelStyle(.iconOnly)` to `Label`-based buttons in toolbars and keyframe navigators to ensure they behave properly as icon-only controls.
## 2026-07-27 - Added missing labels to icon-only buttons in ContentView
**Learning:** Buttons containing only `Label(..., systemImage: ...)` with `.labelStyle(.iconOnly)` in `ContentView` were missing explicit `.accessibilityLabel(...)` modifiers, meaning VoiceOver users would not hear the full context of the button.
**Action:** Always append explicit `.accessibilityLabel(...)` modifiers to any button functioning as an icon-only control to guarantee VoiceOver coverage.
## 2026-08-01 - Add missing label styles to icon-only buttons
**Learning:** Some icon-only buttons built with `Label(..., systemImage: ...)` were missing the `.labelStyle(.iconOnly)` modifier in `InspectorView` and `MediaBinView`, which can lead to visual inconsistencies if the view context expects an icon but renders text.
**Action:** Always append explicit `.labelStyle(.iconOnly)` to any button functioning as an icon-only control when it uses a `Label`, to guarantee it visually renders as an icon.
## 2026-08-04 — Program scene opacity slider: label + value + hide readout

**Learning:** `ProgramSceneEditor`'s layer opacity control used `Slider(...) { Text("Opacity") }` without an explicit `.accessibilityLabel` / `.accessibilityValue`, and left the neighboring `Text("70%")` readout exposed. VoiceOver either announced a generic slider or read the percentage as a separate orphaned element.
**Action:** Pair `.accessibilityLabel("Opacity")` with `.accessibilityValue("…%")` on the `Slider`, hide both the label `Text` inside the slider closure and the visual percentage readout with `.accessibilityHidden(true)`. Prefer `LabeledSliderRow` for new inspector sliders so this pairing lives in one place.
