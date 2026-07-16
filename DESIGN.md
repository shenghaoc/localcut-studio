---
name: LocalCut Studio
description: A native macOS non-linear video editor — TeXShop for video.
colors:
  film-gold: "#F5AB42"
  surface-canvas: "system: Color.black"
  surface-lane: "system: NSColor.underPageBackgroundColor"
  surface-rail: "system: NSColor.windowBackgroundColor"
  caption-fill: "system: Color.indigo"
  caption-stroke: "system: Color.indigo (opacity 0.75)"
  transition-fill: "system: Color.orange"
  beat-marker: "system: Color.yellow (opacity 0.65)"
typography:
  body:
    fontFamily: "SF Pro, -apple-system, sans-serif"
    fontWeight: 400
    fontSize: "system: .body"
  label:
    fontFamily: "SF Pro, -apple-system, sans-serif"
    fontWeight: 400
    fontSize: "system: .caption"
  monospaced:
    fontFamily: "SF Pro, SF Mono, -apple-system, monospace"
    fontSize: "system: .body"
rounded:
  capsule: "full"
  form-row: "system: .grouped form"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
components:
  badge:
    backgroundColor: "system: .thinMaterial"
    rounded: "{rounded.capsule}"
    padding: "10px 5px horizontal, 5px vertical"
  transport-controls:
    backgroundColor: "system: .regular.interactive glass"
    rounded: "{rounded.capsule}"
    padding: "8px 16px"
---

# Design System: LocalCut Studio

## 1. Overview

**Creative North Star: "The Developer's Editor"**

LocalCut Studio is TeXShop for video — an austere, utilitarian tool where every pixel serves the content and nothing shouts for attention. The editor recedes so the work can advance. Visual noise is eliminated by default; decoration is absent.

The system is built on native macOS materials and system colours, not custom palettes. It respects Reduce Motion and Dynamic Type, and uses SF Symbols for all iconography. The editor chrome is deliberately dark (`.preferredColorScheme(.dark)`) as a product choice; system colours still adapt within that mode. The single deliberate colour choice — a warm Film Gold accent — is the only departure from system semantics, and it is used sparingly: selection highlights, focus rings, and key affordances.

**Key Characteristics:**
- Dark chrome by default; system appearance adaptive
- One accent (Film Gold), used on ≤10% of any screen
- System semantic colours for backgrounds, text, and separators — never hard-coded greys
- Liquid Glass for interactive floating controls; thin material for non-interactive badges
- SF Pro throughout; no custom fonts
- Grouped forms, capsule badges, borderless icon buttons

This system explicitly rejects: glossy consumer aesthetics (Final Cut Pro), panel overload and visual noise (Kdenlive), cross-platform web-app reskinning, template-driven UIs, and decorative blurs or glass as default wallpaper.

## 2. Colours

A restrained, system-anchored palette. The Film Gold accent is the only branded colour; everything else delegates to macOS semantic colours so the editor adapts to light/dark mode and high-contrast settings without maintenance.

### Primary
- **Film Gold** (#F5AB42, native Display-P3 0.960/0.670/0.260): Selection highlights, focus rings, and the Export button. Used sparingly — its rarity is the point. Defined in `Assets.xcassets/AccentColor.colorset`.

### Neutral
- **Canvas Black** (`Color.black`): The preview background. Always black regardless of appearance — it is a letterbox, not a surface.
- **Lane Surface** (`NSColor.underPageBackgroundColor`): Timeline track lane fill — a recessed surface that reads as background, not void.
- **Rail Surface** (`NSColor.windowBackgroundColor`): Timeline gutter and ruler — a slightly lifted control band above the recessed lanes.
- **System Text** (`.primary`, `.secondary`, `.tertiary`): All body and label text delegates to the system text hierarchy.
- **System Separator** (`NSColor.separatorColor`): Dividers between panels and sections.

### Functional
- **Caption Indigo** (`Color.indigo`): Caption block fill (full opacity) and stroke (75% opacity) on the timeline caption lane.
- **Transition Orange** (`Color.orange`): Transition glyph fill on the timeline, at varying opacities (0.3 / 0.5 / 0.8) by context.
- **Beat Yellow** (`Color.yellow`, opacity 0.65): Beat markers on the timeline ruler.
- **Trim White** (`Color.white`, opacity 0.15): Trim handle hover feedback on the timeline.
- **Transition Icon White** (`Color.white`): Transition glyph icon on the timeline.

### Named Rules
**The One Accent Rule.** Film Gold is used on ≤10% of any given screen. Its rarity is the point. System controls that inherit the accent through `.tint()` (steppers, toggles, side-rail selections) are exempt — the rule targets bespoke gold highlights outside the standard control vocabulary.

**The System-First Rule.** Never hard-code a grey. Backgrounds, text, and separators always delegate to system semantic colours (`underPageBackgroundColor`, `.secondary`, `separatorColor`) so the editor tracks appearance changes automatically.

## 3. Typography

**Body Font:** SF Pro (-apple-system, sans-serif)
**Monospaced Font:** SF Pro / SF Mono (-apple-system, monospace)

**Character:** Native, unadorned, legible. SF Pro is the only typeface — no display/body pairing, no custom fonts. The hierarchy is weight and size within one family, exactly as macOS conventions prescribe. Timecodes and durations use monospaced digits for tabular alignment.

### Hierarchy
- **Headline** (semibold, `.headline`): Panel headers (`EditorPanelHeader`), section titles in the inspector.
- **Body** (regular, `.body`): Inspector labels, media bin item names, status text, form content.
- **Caption** (regular, `.caption`): Badge text, secondary metadata, format readouts. May be `.monospacedDigit()` for numeric values.
- **Label** (regular/semibold, `.caption`): Section sub-headers, category labels ("Recovered", track names). `.weight(.semibold)` for emphasis.

### Named Rules
**The No Custom Fonts Rule.** SF Pro only. No Google Fonts, no Adobe Fonts, no variable font experiments. The editor should look like it shipped with macOS.

**The Monospaced Time Rule.** Every timecode, duration, and frame number uses `.monospacedDigit()` so columns align and numbers don't jump during playback.

## 4. Elevation

Flat by default. The editor uses tonal layering (lighter surfaces above darker recessed ones) rather than shadows. The three exceptions are:

- **Liquid Glass** (`.glassEffect(.regular.interactive())`): The floating transport controls over the preview canvas and the diagnostics HUD. Both are canonical Liquid Glass cases per HIG — interactive controls floating over content.
- **Thin Material** (`.thinMaterial`): Non-interactive badge capsules (format readout, safe-zone label). HIG: glass is reserved for interactive/functional layers; content-layer labels use standard material.

There is no shadow vocabulary. Depth is conveyed through surface colour contrast alone: canvas black < lane surface < rail surface < panel background.

### Named Rules
**The Flat-By-Default Rule.** Surfaces are flat at rest. Glass and materials appear only as functional responses to context (floating over video, labelling content). Never use glass or blur as decoration.

## 5. Components

### Buttons
- **Shape:** System default (`.borderedProminent` uses system radius; borderless icon buttons have no visible shape).
- **Primary:** `.borderedProminent` — Film Gold background with system-chosen foreground label. Used for the single most important action on a screen (Import Media, Export).
- **Borderless:** `.buttonStyle(.borderless)` — no background, system tint for the icon. Default for toolbar and header icon buttons.
- **Hover / Focus:** System default. Every icon-only button has `.help(...)` and `.accessibilityLabel(...)`.

### Badges
- **Style:** `.thinMaterial` background in a Capsule shape.
- **Typography:** `.caption` with `.monospacedDigit()`.
- **Padding:** Horizontal 10pt, vertical 5pt.
- **Use:** Non-interactive informational labels overlaid on content (format readout, safe-zone name, media count pill).

### Transport Controls
- **Style:** Liquid Glass capsule (`.glassEffect(.regular.interactive())`).
- **Layout:** `HStack(spacing: 12)` — skip-back button, play/pause button, timecode display.
- **Typography:** `.monospacedDigit()`, `.foregroundStyle(.secondary)` for timecodes, `.tertiary` for the separator slash.
- **Padding:** Horizontal 16pt, vertical 8pt.
- **Disabled:** Entire control group disables when there's no content.

### Cards / Containers
LocalCut Studio does not use cards. Information is organized into panels (Media Bin, Inspector, Timeline) separated by Dividers, not card boundaries. Nested cards are never used.

### Inputs / Fields
- **Style:** System default text fields and pickers within grouped Forms.
- **Forms:** `.formStyle(.grouped)` for inspector content. Sections use system section headers.

### Navigation
- **Side Rail:** Segmented picker (`.pickerStyle(.segmented)`, `.controlSize(.small)`) for Inspector / Audio / Captions / Tools. A secondary segmented picker within Tools for Beats / Renders / Markers / Program / Publish.
- **Panel Header:** Every panel uses the shared `EditorPanelHeader` pattern: title text + trailing action buttons + `Divider`. The side rail's segmented switcher substitutes for per-pane headers in tabbed contexts.

### Panel Layout
- **EditorPanelHeader:** Title (`.headline`-weight) on the leading side, action buttons trailing, followed by `Divider`.
- **Media Bin:** `EditorPanelHeader("Media")` with count pill and import button → `Divider` → `ScrollView` with `LazyVStack(spacing: 6)` of media items.
- **Inspector:** Grouped `Form` with contextual sections based on selection (clip properties, colour grading, audio fades, project settings).

### Timeline
- **Structure:** Left gutter (track labels, 56pt wide) + horizontally scrollable content with time ruler (36pt height) + one lane per track (56pt height).
- **Lanes:** `lcLane` background; clip blocks are rounded rectangles positioned by time.
- **Playhead:** Red vertical line, draggable head, synchronized with `AVPlayer` time.
- **Clip Colours:** Video clips = blue family, audio clips = green family, selected = Film Gold accent.
- **Trim Handles:** White at 15% opacity on hover.

### View Modifiers
- **`.monospacedCaption()`** — Applies `.font(.caption)`, `.monospacedDigit()`, and `.foregroundStyle(.secondary)` in one call. Use for secondary numeric labels (timecodes, counts, bitrates). Defined in `Theme.swift`.
- **`.tappable()`** — Applies `.contentShape(Rectangle())` so small tappable elements (lane segments, timeline clips) respond reliably across their full frame. Defined in `Theme.swift`.

### Keyframe Navigation Bar
`KeyframeNavBar` is a reusable four-button HStack (previous / add-or-update / remove / next) with `.controlSize(.small)`. Used across speed, look, skin-smooth, clip-transform, and callout-transform keyframe editors. Accepts callbacks and disabled-state booleans; the add/update button label and icon toggle based on `hasKeyframeAtPlayhead`.

### Spacing Tokens
- **`CGFloat.lcInsetStandard`** (12 pt): Standard inset for panel content and grouped sections.
- **`CGFloat.lcInsetCompact`** (8 pt): Compact inset for dense rows, badges, and inline controls.

### Status Dot
`StatusDot(color:)` is an 8×8 pt `Circle` fill indicator. Available for new status and selection pips; existing selection-dot patterns that use conditional `.fill()` may stay as-is when the conditional treatment is clearer inline.

## 6. Do's and Don'ts

### Do:
- **Do** use system semantic colours for all backgrounds, text, and separators — never hard-code a grey.
- **Do** use SF Symbols for all iconography, with `.help(...)` tooltip and `.accessibilityLabel(...)` on every icon-only control.
- **Do** use `.monospacedDigit()` on every timecode, duration, and frame number — prefer `.monospacedCaption()` when the text is also secondary and caption-sized.
- **Do** use Liquid Glass (`.glassEffect`) only for interactive controls floating over content — never as decoration.
- **Do** respect light/dark appearance automatically; test every panel in both modes.
- **Do** disable (don't hide) temporarily unavailable actions, and explain why via `.help`.
- **Do** use the shared `EditorPanelHeader` pattern for every new panel.

### Don't:
- **Don't** use more than one bespoke Film Gold highlight per panel. System controls that inherit accent through `.tint()` are exempt. The accent earns its impact through restraint, not through detinting standard controls.
- **Don't** import custom fonts. SF Pro is the only typeface.
- **Don't** use cards. Organize content into panels separated by Dividers.
- **Don't** nest cards inside cards — this is always wrong.
- **Don't** use glassmorphism, blurs, or materials as decorative wallpaper.
- **Don't** hard-code light-mode-only or dark-mode-only colours that break when the system appearance changes.
- **Don't** reskin macOS to look like a cross-platform web app. Native controls, native materials, native conventions.
- **Don't** overload panels. If a screen has more than one primary action button, reconsider the hierarchy.
- **Don't** let text overflow its container — test every panel at the largest Dynamic Type size.
