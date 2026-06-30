import Foundation
import AppKit
import CoreMedia
import LocalCutCore

/// Records own-app user interactions (mouse, scroll, key) during a capture
/// session using `NSEvent.addLocalMonitorForEvents`. Events are accumulated
/// in memory and flushed to `events.json` on stop.
///
/// Local monitors see only events delivered to our own app — no Accessibility
/// permission is required, and no cross-application tracking occurs.
@MainActor
final class ScreencastEventLogWriter {
    private let sessionID: UUID
    private let startHostTimeUs: Int64
    private let outputURL: URL
    private var events: [ScreencastEvent] = []
    private var monitor: Any?

    /// Creates a writer that will store events relative to the given start time.
    ///
    /// - Parameters:
    ///   - sessionID: The capture session UUID.
    ///   - startHostTimeUs: The capture start time in host-time microseconds.
    ///   - directoryURL: The capture session directory where `events.json` will
    ///     be written.
    nonisolated init(sessionID: UUID, startHostTimeUs: Int64, directoryURL: URL) {
        self.sessionID = sessionID
        self.startHostTimeUs = startHostTimeUs
        self.outputURL = directoryURL.appendingPathComponent("events.json")
    }

    /// Begin monitoring local NSEvents. Must be called on the main actor.
    func startMonitoring() {
        // Ensure any previous monitor is removed first.
        stopMonitoring()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel,
            .keyDown, .keyUp,
        ]) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    /// Stop monitoring and flush accumulated events to disk.
    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Remove the monitor as a safety net (e.g. from deinit).
    deinit {
        // Monitor is @MainActor-isolated; deinit runs on an arbitrary thread.
        // This is a safety net — stopMonitoring() should have already removed it.
    }

    /// Returns the accumulated events (for testing).
    func currentEvents() -> [ScreencastEvent] {
        events
    }

    /// Flush the accumulated events to `events.json`.
    func flush() throws {
        let log = ScreencastEventLog(
            schemaVersion: ScreencastEventLog.currentSchemaVersion,
            sessionID: sessionID,
            events: events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(log)
        try data.write(to: outputURL, options: .atomic)
    }

    // MARK: - Private

    private func record(_ event: NSEvent) {
        let nowUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let relativeUs = nowUs - startHostTimeUs
        guard relativeUs >= 0 else { return }
        let time = CMTime(value: relativeUs, timescale: CaptureManifest.microsecondTimescale)

        let kind: ScreencastEventKind
        var position: CGPoint?
        var keyCode: UInt16?
        var modifierFlagsRaw: UInt?

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseDown
            position = Self.normalizedPosition(from: event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouseUp
            position = Self.normalizedPosition(from: event)
        case .scrollWheel:
            kind = .scroll
            position = Self.normalizedPosition(from: event)
        case .keyDown:
            kind = .key
            keyCode = event.keyCode
            modifierFlagsRaw = event.modifierFlags.rawValue
        case .keyUp:
            kind = .key
            keyCode = event.keyCode
            modifierFlagsRaw = event.modifierFlags.rawValue
        default:
            return
        }

        events.append(ScreencastEvent(
            time: time,
            kind: kind,
            position: position,
            keyCode: keyCode,
            modifierFlagsRaw: modifierFlagsRaw))
    }

    /// Convert window-local coordinates to normalised 0...1 relative to the
    /// window bounds. Returns nil if the window size is unavailable.
    private static func normalizedPosition(from event: NSEvent) -> CGPoint? {
        guard let window = event.window,
              window.frame.width > 0, window.frame.height > 0 else {
            return nil
        }
        let loc = event.locationInWindow
        // Clamp to window bounds to avoid out-of-range values.
        let clampedX = max(0, min(loc.x, window.frame.width))
        let clampedY = max(0, min(loc.y, window.frame.height))
        return CGPoint(
            x: clampedX / window.frame.width,
            y: clampedY / window.frame.height)
    }
}

// MARK: - Own-App Detection

extension CaptureTarget {
    /// Returns true if this capture target is recording LocalCut Studio itself.
    nonisolated var isOwnApp: Bool {
        switch self {
        case .application(_, let bundleIdentifier, _, _, _, _):
            return bundleIdentifier == Bundle.main.bundleIdentifier
        case .display, .window:
            return false
        }
    }
}
