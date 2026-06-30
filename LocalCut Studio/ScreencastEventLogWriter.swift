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
    private var captureRegion: CaptureRegion?
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
    ///   - target: The capture target.
    ///   - captureRegion: Optional region within the display being captured.
    nonisolated init(sessionID: UUID,
                     startHostTimeUs: Int64,
                     directoryURL: URL,
                     target: CaptureTarget,
                     captureRegion: CaptureRegion? = nil) {
        self.sessionID = sessionID
        self.startHostTimeUs = startHostTimeUs
        self.outputURL = directoryURL.appendingPathComponent("events.json")
        self.target = target
        self.captureRegion = captureRegion
    }

    /// Begin monitoring events for the current target.
    func startMonitoring() {
        stopMonitoring()

        if target.isOwnApp {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.localEventMask) { [weak self] event in
                // Extract Sendable values before entering assumeIsolated.
                let eventType = event.type
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                let locationInWindow = event.locationInWindow
                let windowSize = event.window?.frame.size
                MainActor.assumeIsolated {
                    self?.recordFromMonitor(
                        eventType: eventType,
                        locationInWindow: locationInWindow,
                        windowSize: windowSize,
                        keyCode: keyCode,
                        modifierFlags: modifiers,
                        source: .ownAppLocal)
                }
                return event
            }
        } else {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.globalEventMask) { [weak self] event in
                // Extract Sendable values before entering assumeIsolated.
                let eventType = event.type
                let locationInWindow = event.locationInWindow
                let windowSize = event.window?.frame.size
                MainActor.assumeIsolated {
                    self?.recordFromMonitor(
                        eventType: eventType,
                        locationInWindow: locationInWindow,
                        windowSize: windowSize,
                        keyCode: 0,
                        modifierFlags: [],
                        source: .globalTarget)
                }
            }
        }
    }

    /// Switch event-coordinate mapping when the live recorder switches source.
    func updateTarget(_ newTarget: CaptureTarget, captureRegion: CaptureRegion? = nil) {
        let wasMonitoring = localMonitor != nil || globalMonitor != nil
        if wasMonitoring {
            stopMonitoring()
        }
        target = newTarget
        self.captureRegion = captureRegion
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

    /// Remove the monitor as a safety net. `NSEvent.removeMonitor` must run on
    /// the main thread but `deinit` can be called from any executor, so dispatch
    /// the removal. The monitor handler captures `self` weakly, so any events
    /// arriving between deallocation and the async removal are harmless.
    deinit {
        let local = localMonitor
        let global = globalMonitor
        DispatchQueue.main.async {
            if let local { NSEvent.removeMonitor(local) }
            if let global { NSEvent.removeMonitor(global) }
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

    /// Record an event using pre-extracted Sendable values so the caller can
    /// pass them through `MainActor.assumeIsolated` without capturing the
    /// non-Sendable `NSEvent`.
    private func recordFromMonitor(
        eventType: NSEvent.EventType,
        locationInWindow: CGPoint,
        windowSize: CGSize?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        source: EventSource
    ) {
        let nowUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let relativeUs = nowUs - startHostTimeUs
        guard relativeUs >= 0 else { return }
        let time = CMTime(value: relativeUs, timescale: CaptureManifest.microsecondTimescale)

        let kind: ScreencastEventKind
        var position: CGPoint?

        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseDown
            position = normalizedPositionFromMonitor(
                locationInWindow: locationInWindow,
                windowSize: windowSize,
                source: source)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouseUp
            position = normalizedPositionFromMonitor(
                locationInWindow: locationInWindow,
                windowSize: windowSize,
                source: source)
        case .scrollWheel:
            kind = .scroll
            position = normalizedPositionFromMonitor(
                locationInWindow: locationInWindow,
                windowSize: windowSize,
                source: source)
        case .keyDown, .keyUp where source == .ownAppLocal:
            kind = .key
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
            keyCode: source == .ownAppLocal ? keyCode : nil,
            modifierFlagsRaw: source == .ownAppLocal ? modifierFlags.rawValue : nil))
    }

    /// Compute normalised position from pre-extracted Sendable values.
    private func normalizedPositionFromMonitor(
        locationInWindow: CGPoint,
        windowSize: CGSize?,
        source: EventSource
    ) -> CGPoint? {
        if source == .ownAppLocal {
            guard let size = windowSize, size.width > 0, size.height > 0 else { return nil }
            let clampedX = max(0, min(locationInWindow.x, size.width))
            let clampedY = max(0, min(locationInWindow.y, size.height))
            return CGPoint(x: clampedX / size.width, y: clampedY / size.height)
        }

        switch target {
        case .display(let displayID, _, _):
            if let region = captureRegion, region.displayID == displayID {
                return Self.normalizedRegionPosition(region: region, point: NSEvent.mouseLocation)
            }
            return Self.normalizedScreenPosition(displayID: displayID, point: NSEvent.mouseLocation)
        case .window(_, _, _, let width, let height):
            return Self.normalizedWindowPosition(
                location: locationInWindow,
                width: CGFloat(width),
                height: CGFloat(height))
        case .application(_, _, _, let displayID, _, _):
            if let region = captureRegion, region.displayID == displayID {
                return Self.normalizedRegionPosition(region: region, point: NSEvent.mouseLocation)
            }
            return Self.normalizedScreenPosition(displayID: displayID, point: NSEvent.mouseLocation)
        }
    }

    private func normalizedPosition(from event: NSEvent, source: EventSource) -> CGPoint? {
        if source == .ownAppLocal {
            return Self.normalizedWindowPosition(from: event)
        }

        switch target {
        case .display(let displayID, _, _):
            if let region = captureRegion, region.displayID == displayID {
                return Self.normalizedRegionPosition(region: region, point: NSEvent.mouseLocation)
            }
            return Self.normalizedScreenPosition(displayID: displayID, point: NSEvent.mouseLocation)
        case .window(_, _, _, let width, let height):
            // Note: event.windowNumber (AppKit) and CGWindowID use different
            // numbering schemes, so we cannot filter by window ID here. The
            // global monitor receives system-wide events; we normalise to the
            // target window's dimensions.
            return Self.normalizedWindowPosition(
                location: event.locationInWindow,
                width: CGFloat(width),
                height: CGFloat(height))
        case .application(_, _, _, let displayID, _, _):
            if let region = captureRegion, region.displayID == displayID {
                return Self.normalizedRegionPosition(region: region, point: NSEvent.mouseLocation)
            }
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

    /// Normalise a screen-space point to 0...1 relative to the captured region
    /// within the display. Points outside the region return nil.
    private static func normalizedRegionPosition(region: CaptureRegion, point: CGPoint) -> CGPoint? {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == region.displayID
        }) else { return nil }
        let screenFrame = screen.frame
        // Convert sourceRect (origin bottom-left) to screen coordinates.
        let regionRect = CGRect(
            x: screenFrame.minX + region.sourceRect.minX,
            y: screenFrame.maxY - region.sourceRect.maxY,
            width: region.sourceRect.width,
            height: region.sourceRect.height)
        guard regionRect.width > 0, regionRect.height > 0 else { return nil }
        let nx = (point.x - regionRect.minX) / regionRect.width
        let ny = (point.y - regionRect.minY) / regionRect.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return CGPoint(x: nx, y: ny)
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
