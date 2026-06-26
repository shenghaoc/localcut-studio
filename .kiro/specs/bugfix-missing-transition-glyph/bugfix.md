# Bugfix: Missing Transition Toolbar Glyph

> Status: **Complete**.

Pre-existing UI bug found while reviewing the editor toolbar for PR #48. It is
unrelated to PR #48's scope: the toolbar's transition button has always rendered
as a blank white circle because its SF Symbol name does not exist on the
shipping OS.

## Bugs

### B1 - "Add Transition" toolbar button renders as a blank glyph

The transition toolbar button (`EditorView.toolbarContent`, between **Split**
and **Delete**) used the SF Symbol name
`square.filled.and.line.vertical.and.square.filled`. That name does not resolve
on this OS — `NSImage(systemSymbolName:accessibilityDescription:)` returns `nil`
— so the button drew the system's missing-symbol placeholder (a blank circle).
The action worked, but the control was unreadable.

- **Fix**: Replace the symbol with
  `arrow.left.and.right.righttriangle.left.righttriangle.right` — a valid symbol
  whose two-triangles-meeting form reads as a dissolve / transition (the
  iMovie / Final Cut metaphor). Verified present via
  `NSImage(systemSymbolName:)` on the build OS.
- **Verification**: swept every `systemImage:` / `Image(systemName:)` string in
  the app target through `NSImage(systemSymbolName:)`; this was the only missing
  one — the other 25 all resolve.
- **Impact**: the toolbar button is now legible; no behaviour change.
