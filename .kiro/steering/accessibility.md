# Accessibility

Target the same bar Apple sets for its own pro apps. The two relevant accessibility "nutrition labels" here are **VoiceOver** and **Dynamic Type**; there are project skills for auditing both.

## VoiceOver

- Every icon-only control (toolbar buttons, transport, the bin "+", zoom glyphs) has a human-readable `accessibilityLabel`. `.help(...)` is not a substitute for a label.
- Clip blocks expose a meaningful label (media name + start + duration), and selection state is reflected (`accessibilityAddTraits(.isSelected)`).
- The status line is an announced live region for background work and errors.
- Custom controls (timeline ruler/playhead, clip blocks) are reachable and operable, not just decorative.

## Keyboard

- All primary actions have shortcuts: Space (play/pause), Delete (remove clip), and standard menu equivalents. No action is mouse-only.
- Focus is visible (`:focus`/`focusable` with a clear ring); no focus traps. Dialogs/sheets close with Escape.
- Tab order follows visual order across panes.

## Dynamic Type & layout

- Text uses system text styles (`.headline`, `.caption`, …) so it scales; avoid fixed point sizes for body text.
- Layouts reflow rather than truncate critical information at large sizes; the inspector `Form` and bin rows must remain usable.

## Contrast & motion

- Meet contrast ratios in both light and dark; don't rely on colour alone to convey state (pair colour with shape/label, e.g. selection border + accent).
- Respect Reduce Motion for any animated affordance added later (transitions preview, scrubbing inertia).

## Checklist

Before merging UI changes, run the relevant skill audits and tick [`A11Y-CHECKLIST.md`](../../A11Y-CHECKLIST.md).
