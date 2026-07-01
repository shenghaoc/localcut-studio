import Foundation
import CoreMedia

// MARK: - Keystroke Overlay Generator

/// Converts a Phase 43 `ScreencastEventLog` into a `KeystrokeOverlayClip`
/// with display-ready `KeystrokeOverlayEvent` entries.
public enum KeystrokeOverlayGenerator: Sendable {

    /// NSEvent.ModifierFlags raw values (AppKit-free).
    private static let modifierFlagShift: UInt   = 0x0002_0000
    private static let modifierFlagControl: UInt = 0x0004_0000
    private static let modifierFlagOption: UInt  = 0x0008_0000
    private static let modifierFlagCommand: UInt = 0x0010_0000

    /// Generates a `KeystrokeOverlayClip` from an event log.
    ///
    /// - Parameters:
    ///   - log: The source event log.
    ///   - style: Overlay style parameters.
    /// - Returns: A clip with events derived from `.key` entries, or `nil` if
    ///   the log has no key events.
    public static func generate(
        from log: ScreencastEventLog,
        style: KeystrokeOverlayStyle = KeystrokeOverlayStyle()
    ) -> KeystrokeOverlayClip? {
        guard log.isSupportedSchema else { return nil }

        // Filter to .key events and deduplicate key-down/key-up pairs.
        // The event log records both NSEvent.keyDown and .keyUp as .key;
        // they share the same keyCode and timestamp, so keeping only the
        // first event per (keyCode, time) pair drops the key-up duplicate.
        let keyEvents = log.events.filter { $0.kind == .key }
        guard !keyEvents.isEmpty else { return nil }
        var seenKeys = Set<UInt16>()
        let deduplicated = keyEvents.filter { event in
            guard let keyCode = event.keyCode else { return false }
            // For character keys, only keep the first event per keyCode.
            // Modifier keys may legitimately repeat, so allow them through.
            let isModifier = (event.modifierFlagsRaw ?? 0) & 0x1E0000 != 0
            if isModifier { return true }
            if seenKeys.contains(keyCode) { return false }
            seenKeys.insert(keyCode)
            return true
        }

        let events = deduplicated.compactMap { event -> KeystrokeOverlayEvent? in
            guard let keyCode = event.keyCode else { return nil }
            let modifiers = event.modifierFlagsRaw ?? 0
            let (text, mode) = displayTextAndMode(keyCode: keyCode, modifierFlags: modifiers)
            guard !text.isEmpty else { return nil }
            return KeystrokeOverlayEvent(
                time: event.time,
                displayText: text,
                displayMode: mode)
        }

        guard !events.isEmpty else { return nil }

        let earliest = events.map(\.time).min() ?? .zero
        let latest = events.map(\.time).max() ?? .zero
        let holdDuration = CMTime(seconds: Double(style.holdDuration + style.fadeOutDuration),
                                  preferredTimescale: 600)
        let duration = latest - earliest + holdDuration + CMTime(seconds: 1, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: earliest, duration: max(CMTime(seconds: 1, preferredTimescale: 600), duration))

        return KeystrokeOverlayClip(
            sourceSessionID: log.sessionID,
            timeRange: timeRange,
            events: events,
            style: style)
    }

    // MARK: - Key Code Mapping

    /// Maps a virtual key code and modifier flags to a display string and mode.
    private static func displayTextAndMode(
        keyCode: UInt16,
        modifierFlags: UInt
    ) -> (String, KeystrokeDisplayMode) {
        // Check if this is a modifier-only press.
        let hasShift = modifierFlags & modifierFlagShift != 0
        let hasControl = modifierFlags & modifierFlagControl != 0
        let hasOption = modifierFlags & modifierFlagOption != 0
        let hasCommand = modifierFlags & modifierFlagCommand != 0

        // Build modifier chip string.
        var modifierChips = ""
        if hasCommand { modifierChips += "\u{2318}" }
        if hasShift { modifierChips += "\u{21E7}" }
        if hasOption { modifierChips += "\u{2325}" }
        if hasControl { modifierChips += "\u{2303}" }

        // Map the key code to a character.
        let keyChar = characterForKeyCode(keyCode)

        if let keyChar {
            if modifierChips.isEmpty {
                return (keyChar, .character)
            } else {
                return (modifierChips + keyChar, .modifier)
            }
        } else {
            // No character mapping — treat as special or modifier-only.
            if !modifierChips.isEmpty {
                return (modifierChips, .modifier)
            }
            // Unknown key with no modifiers.
            return ("", .special)
        }
    }

    /// Maps common macOS virtual key codes to display characters.
    private static func characterForKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        // Letters (QWERTY layout)
        case 0x00: return "A"
        case 0x0B: return "B"
        case 0x08: return "C"
        case 0x02: return "D"
        case 0x0E: return "E"
        case 0x03: return "F"
        case 0x05: return "G"
        case 0x04: return "H"
        case 0x22: return "I"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x25: return "L"
        case 0x2E: return "M"
        case 0x2D: return "N"
        case 0x1F: return "O"
        case 0x23: return "P"
        case 0x0C: return "Q"
        case 0x0F: return "R"
        case 0x01: return "S"
        case 0x11: return "T"
        case 0x20: return "U"
        case 0x09: return "V"
        case 0x0D: return "W"
        case 0x07: return "X"
        case 0x10: return "Y"
        case 0x06: return "Z"

        // Numbers
        case 0x1D: return "0"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x17: return "5"
        case 0x16: return "6"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x19: return "9"

        // Special keys
        case 0x24: return "\u{21A9}" // Return
        case 0x30: return "\u{21E5}" // Tab
        case 0x31: return "\u{2423}" // Space
        case 0x33: return "\u{232B}" // Delete (Backspace)
        case 0x35: return "\u{238B}" // Escape
        case 0x7E: return "\u{2191}" // Up Arrow
        case 0x7D: return "\u{2193}" // Down Arrow
        case 0x7B: return "\u{2190}" // Left Arrow
        case 0x7C: return "\u{2192}" // Right Arrow

        // Punctuation
        case 0x27: return "'"
        case 0x2A: return "\\"
        case 0x2B: return ","
        case 0x2C: return "/"
        case 0x2F: return "."
        case 0x32: return "`"
        case 0x38: return "-"
        case 0x39: return "\u{21EA}" // Caps Lock
        case 0x41: return "."
        case 0x43: return "*"
        case 0x45: return "+"
        case 0x4E: return "-"
        case 0x51: return "="

        // Function keys
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"

        default: return nil
        }
    }
}
