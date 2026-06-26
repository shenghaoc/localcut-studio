# Tasks: Missing Transition Toolbar Glyph

> Status: **Complete**.

## Implementation

- [x] **T1.1** Replace the transition button's non-existent SF Symbol
  (`square.filled.and.line.vertical.and.square.filled`) with the verified
  `arrow.left.and.right.righttriangle.left.righttriangle.right`.

## Verification

- [x] **V1** `NSImage(systemSymbolName:)` resolves the new symbol on the build
  OS and returned `nil` for the old one (confirming the bug).
- [x] **V2** Every `systemImage:` / `Image(systemName:)` string in the app target
  resolves via `NSImage(systemSymbolName:)` — no other blank glyphs.
- [x] **V3** Project builds cleanly (Debug, macOS).
