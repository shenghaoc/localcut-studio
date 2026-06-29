import Foundation
import CoreMedia
import AppKit
import LocalCutCore

/// A single input event captured during an own-app recording session.
///
/// Events are written to a sidecar `events.json` file alongside the capture
/// session manifest. The log is used by the auto-zoom proposer to generate
/// zoom-pan keyframe suggestions around click clusters.
struct CaptureEvent: Codable, Sendable {
    /// Time relative to the capture session start.
    let time: CMTime
    /// The kind of input event.
    let kind: Kind
    /// Location in the app's window coordinates (points, not pixels).
    let position: CGPoint

    enum Kind: String, Codable, Sendable {
        case mouseDown
        case mouseUp
        case scroll
        case key
    }

    private enum CodingKeys: String, CodingKey {
        case time, kind, position
    }

    init(time: CMTime, kind: Kind, position: CGPoint) {
        self.time = time
        self.kind = kind
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        kind = try c.decode(Kind.self, forKey: .kind)
        let pos = try c.decode(Position.self, forKey: .position)
        position = CGPoint(x: pos.x, y: pos.y)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(kind, forKey: .kind)
        try c.encode(Position(x: position.x, y: position.y), forKey: .position)
    }

    private struct Position: Codable {
        let x: Double
        let y: Double
    }
}

/// Monitors local input events during an own-app capture session and writes
/// them to a sidecar `events.json` file.
///
/// Uses `NSEvent.addLocalMonitorForEvents` which only sees events delivered to
/// our own app — no Accessibility permission required. The monitor is started
/// at session open and stopped at session close; the token is removed in both
/// `stop()` and `deinit` (belt-and-braces).
final class CaptureEventMonitor: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var monitor: Any?
    private var _events: [CaptureEvent] = []
    private var _sessionStart: Date?
    private let outputURL: URL

    /// Creates a monitor that will write events to `events.json` in the given
    /// directory.
    init(outputDirectory: URL) {
        self.outputURL = outputDirectory.appendingPathComponent("events.json")
    }

    deinit {
        lock.lock()
        let m = monitor
        monitor = nil
        lock.unlock()
        if let m {
            NSEvent.removeMonitor(m)
        }
    }

    /// Starts monitoring local input events. `sessionStart` is used to compute
    /// CMTime offsets relative to the capture session.
    func start(sessionStart: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        _sessionStart = sessionStart
        _events = []

        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel,
            .keyDown, .keyUp,
        ]) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
    }

    /// Stops monitoring and writes the collected events to disk.
    func stop() {
        lock.lock()
        let m = monitor
        let events = _events
        monitor = nil
        _sessionStart = nil
        lock.unlock()

        if let m {
            NSEvent.removeMonitor(m)
        }

        guard !events.isEmpty else { return }
        writeEvents(events)
    }

    /// Returns a copy of the currently collected events.
    var events: [CaptureEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    private func handleEvent(_ event: NSEvent) {
        lock.lock()
        defer { lock.unlock() }

        guard let sessionStart = _sessionStart else { return }
        let elapsed = Date().timeIntervalSince(sessionStart)
        let time = CMTime(seconds: elapsed, preferredTimescale: 600)

        let kind: CaptureEvent.Kind
        let position: CGPoint

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouseDown
            position = event.locationInWindow
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouseUp
            position = event.locationInWindow
        case .scrollWheel:
            kind = .scroll
            position = event.locationInWindow
        case .keyDown:
            kind = .key
            position = event.locationInWindow
        case .keyUp:
            kind = .key
            position = event.locationInWindow
        default:
            return
        }

        _events.append(CaptureEvent(time: time, kind: kind, position: position))
    }

    private func writeEvents(_ events: [CaptureEvent]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(events)
            try data.write(to: outputURL, options: [.atomic])
        } catch {
            // Best-effort: event logging is non-critical.
            print("CaptureEventMonitor: failed to write events.json: \(error)")
        }
    }
}

/// Reads a previously-written `events.json` sidecar file.
func readCaptureEvents(from directory: URL) -> [CaptureEvent]? {
    let url = directory.appendingPathComponent("events.json")
    guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CaptureEvent].self, from: data)
    } catch {
        return nil
    }
}
