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
                let screenLocation = NSEvent.mouseLocation
                MainActor.assumeIsolated {
                    self?.recordFromMonitor(
                        eventType: eventType,
                        locationInWindow: locationInWindow,
                        screenLocation: screenLocation,
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
                let screenLocation = NSEvent.mouseLocation
                MainActor.assumeIsolated {
                    self?.recordFromMonitor(
                        eventType: eventType,
                        locationInWindow: locationInWindow,
                        screenLocation: screenLocation,
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

    /// Capture a snapshot of the accumulated events. Must be called on the
    /// main actor since `events` is actor-isolated.
    func snapshotEvents() -> [ScreencastEvent] {
        events
    }

    /// Flush the accumulated events to `events.json`. The caller must pass
    /// the event snapshot so this method can run on any thread.
    nonisolated func flush(events: [ScreencastEvent]) throws {
        try Self.writeLog(sessionID: sessionID, events: events, outputURL: outputURL)
    }

    nonisolated func flushDetached(events: [ScreencastEvent]) async throws {
        let sessionID = sessionID
        let outputURL = outputURL
        try await Task.detached(priority: .utility) {
            try Self.writeLog(sessionID: sessionID, events: events, outputURL: outputURL)
        }.value
    }

    private nonisolated static func writeLog(
        sessionID: UUID,
        events: [ScreencastEvent],
        outputURL: URL
    ) throws {
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

    /// Record an event using pre-extracted Sendable values so the caller can
    /// pass them through `MainActor.assumeIsolated` without capturing the
    /// non-Sendable `NSEvent`.
    private func recordFromMonitor(
        eventType: NSEvent.EventType,
        locationInWindow: CGPoint,
        screenLocation: CGPoint,
        windowSize: CGSize?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        source: ScreencastEventMonitorSource
    ) {
        let nowUs = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let relativeUs = nowUs - startHostTimeUs
        guard relativeUs >= 0 else { return }
        let time = CMTime(value: relativeUs, timescale: CaptureManifest.microsecondTimescale)

        let kind: ScreencastEventKind
        var position: CGPoint?
        let keyPhase: ScreencastKeyPhase?

        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseDown
            keyPhase = nil
            position = normalizedPositionFromMonitor(
                locationInWindow: locationInWindow,
                screenLocation: screenLocation,
                windowSize: windowSize,
                source: source)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouseUp
            keyPhase = nil
            position = normalizedPositionFromMonitor(
                locationInWindow: locationInWindow,
                screenLocation: screenLocation,
                windowSize: windowSize,
                source: source)
        case .scrollWheel:
            kind = .scroll
            keyPhase = nil
            position = normalizedPositionFromMonitor(
                locationInWindow: locationInWindow,
                screenLocation: screenLocation,
                windowSize: windowSize,
                source: source)
        case .keyDown where source == .ownAppLocal:
            kind = .key
            keyPhase = .down
        case .keyUp where source == .ownAppLocal:
            kind = .key
            keyPhase = .up
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
            modifierFlagsRaw: source == .ownAppLocal ? modifierFlags.rawValue : nil,
            keyPhase: keyPhase))
    }

    /// Compute normalised position from pre-extracted Sendable values.
    private func normalizedPositionFromMonitor(
        locationInWindow: CGPoint,
        screenLocation: CGPoint,
        windowSize: CGSize?,
        source: ScreencastEventMonitorSource
    ) -> CGPoint? {
        ScreencastEventCoordinateMapper.normalizedPosition(
            target: target,
            captureRegion: captureRegion,
            monitorSource: source,
            screenLocation: screenLocation,
            locationInWindow: locationInWindow,
            windowSize: windowSize)
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
