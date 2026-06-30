import Foundation
import AppKit
import CoreMedia
import LocalCutCore

/// Records user interactions during a capture session. Own-app recordings use
/// a local monitor and include key codes. Screen/window/application recordings
/// outside LocalCut use a global mouse/scroll monitor so auto-zoom can still
/// consume click positions without requesting Accessibility or logging text.
@MainActor
final class ScreencastEventLogWriter {
    private let sessionID: UUID
    private let startHostTimeUs: Int64
    private let outputURL: URL
    private var target: CaptureTarget
    private var events: [ScreencastEvent] = []
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var globalMonitor: Any?

    /// Creates a writer that will store events relative to the given start time.
    ///
    /// - Parameters:
    ///   - sessionID: The capture session UUID.
    ///   - startHostTimeUs: The capture start time in host-time microseconds.
    ///   - directoryURL: The capture session directory where `events.json` will
    ///     be written.
    nonisolated init(sessionID: UUID,
                     startHostTimeUs: Int64,
                     directoryURL: URL,
                     target: CaptureTarget) {
        self.sessionID = sessionID
        self.startHostTimeUs = startHostTimeUs
        self.outputURL = directoryURL.appendingPathComponent("events.json")
        self.target = target
    }

    /// Begin monitoring events for the current target.
    func startMonitoring() {
        stopMonitoring()

        if target.isOwnApp {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.localEventMask) { [weak self] event in
                self?.record(event, source: .ownAppLocal)
                return event
            }
        } else {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.globalEventMask) { [weak self] event in
                self?.record(event, source: .globalTarget)
            }
        }
    }

    /// Switch event-coordinate mapping when the live recorder switches source.
    func updateTarget(_ newTarget: CaptureTarget) {
        let wasMonitoring = localMonitor != nil || globalMonitor != nil
        if wasMonitoring {
            stopMonitoring()
        }
        target = newTarget
        if wasMonitoring {
            startMonitoring()
        }
    }

    /// Stop monitoring without flushing accumulated events.
    func stopMonitoring() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    /// Remove the monitor as a safety net.
    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
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

    private enum EventSource: Equatable {
        case ownAppLocal
        case globalTarget
    }

    private static let localEventMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .scrollWheel,
        .keyDown, .keyUp,
    ]

    private static let globalEventMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .scrollWheel,
    ]

    private func record(_ event: NSEvent, source: EventSource) {
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
            position = normalizedPosition(from: event, source: source)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouseUp
            position = normalizedPosition(from: event, source: source)
        case .scrollWheel:
            kind = .scroll
            position = normalizedPosition(from: event, source: source)
        case .keyDown, .keyUp where source == .ownAppLocal:
            kind = .key
            keyCode = event.keyCode
            modifierFlagsRaw = event.modifierFlags.rawValue
        default:
            return
        }

        if source == .globalTarget, position == nil {
            return
        }

        events.append(ScreencastEvent(
            time: time,
            kind: kind,
            position: position,
            keyCode: keyCode,
            modifierFlagsRaw: modifierFlagsRaw))
    }

    private func normalizedPosition(from event: NSEvent, source: EventSource) -> CGPoint? {
        if source == .ownAppLocal {
            return Self.normalizedWindowPosition(from: event)
        }

        switch target {
        case .display(let displayID, _, _):
            return Self.normalizedScreenPosition(displayID: displayID, point: NSEvent.mouseLocation)
        case .window(let windowID, _, _, let width, let height):
            guard event.windowNumber == Int(windowID) else { return nil }
            return Self.normalizedWindowPosition(
                location: event.locationInWindow,
                width: CGFloat(width),
                height: CGFloat(height))
        case .application(_, _, _, let displayID, _, _):
            return Self.normalizedScreenPosition(displayID: displayID, point: NSEvent.mouseLocation)
        }
    }

    private static func normalizedWindowPosition(from event: NSEvent) -> CGPoint? {
        guard let window = event.window else { return nil }
        return normalizedWindowPosition(
            location: event.locationInWindow,
            width: window.frame.width,
            height: window.frame.height)
    }

    private static func normalizedWindowPosition(location: CGPoint,
                                                 width: CGFloat,
                                                 height: CGFloat) -> CGPoint? {
        guard width > 0, height > 0 else { return nil }
        let clampedX = max(0, min(location.x, width))
        let clampedY = max(0, min(location.y, height))
        return CGPoint(x: clampedX / width, y: clampedY / height)
    }

    private static func normalizedScreenPosition(displayID: UInt32, point: CGPoint) -> CGPoint? {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }) else { return nil }
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height)
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
