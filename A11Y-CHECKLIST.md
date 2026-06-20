# Accessibility Checklist

Run before merging any UI change. Backed by [`.kiro/steering/accessibility.md`](.kiro/steering/accessibility.md) and the `accessibility-voiceover-specialist` / `accessibility-dynamic-type-specialist` skills.

## VoiceOver

- [ ] Every icon-only control has an accessibility label (toolbar, transport, bin "+", zoom glyphs)
- [ ] Clip blocks expose name + start + duration and reflect selection (`.isSelected` trait)
- [ ] Status line is an announced live region for background work and errors
- [ ] Custom timeline controls (ruler, playhead, clips) are reachable and operable
- [ ] Labels are human-readable (no raw identifiers or symbol names)

## Keyboard

- [ ] All primary actions have shortcuts (Space play/pause, Delete remove, menu equivalents)
- [ ] No mouse-only action; tab order follows visual order
- [ ] Focus indicator is visible; no focus traps; sheets close with Escape

## Dynamic Type & layout

- [ ] Text uses system text styles, not fixed sizes
- [ ] Inspector form and bin rows remain usable at large sizes (reflow, no critical truncation)

## Contrast & motion

- [ ] Contrast meets ratios in light and dark
- [ ] State is not conveyed by colour alone (selection = accent border + colour)
- [ ] Animated affordances respect Reduce Motion

## Per-PR

- [ ] Ran the relevant accessibility skill audit on changed views
- [ ] New controls added to this checklist if they introduce new patterns
