# Design: Missing Transition Toolbar Glyph

A one-line symbol-name correction plus a guard against the class of bug.

## Root cause

SF Symbol names are validated at *runtime*, not compile time. `Image(systemName:)`
/ `Label(_:systemImage:)` with an unknown name compile cleanly and silently draw
a placeholder, so a wrong/renamed/too-new symbol ships as a blank glyph. The
transition button's name was simply not a real symbol on this OS baseline.

## Approach

1. Swap the name for a verified symbol that communicates "transition":
   `arrow.left.and.right.righttriangle.left.righttriangle.right`.
2. Verify existence the only reliable way — at runtime:
   `NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil`.
3. Sweep the whole app target for other missing names so no other blank glyph
   lurks.

The button keeps its `.help(...)` tooltip and `.accessibilityLabel`, so the
swap is purely visual.

## Scope

Touched: one `systemImage:` string in `ContentView.swift`.

## Non-goals

- No toolbar layout, action, or label-text change.
- No change to the side rail or any other view (that is PR #48's feature work).
