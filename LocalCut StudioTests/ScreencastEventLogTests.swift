import Testing
import Foundation
import CoreMedia
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - Own-App Detection

@Suite("CaptureTarget own-app detection")
struct CaptureTargetOwnAppTests {
    @Test("Application target matching bundle ID is own-app")
    func applicationIsOwnApp() {
        let target = CaptureTarget.application(
            processID: Int32(ProcessInfo.processInfo.processIdentifier),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.test",
            name: "LocalCut Studio",
            displayID: 1,
            width: 1920,
            height: 1080)
        #expect(target.isOwnApp)
    }

    @Test("Application target with different bundle ID is not own-app")
    func applicationNotOwnApp() {
        let target = CaptureTarget.application(
            processID: 999,
            bundleIdentifier: "com.other.app",
            name: "Other App",
            displayID: 1,
            width: 1920,
            height: 1080)
        #expect(!target.isOwnApp)
    }

    @Test("Display target is not own-app")
    func displayNotOwnApp() {
        let target = CaptureTarget.display(displayID: 1, width: 1920, height: 1080)
        #expect(!target.isOwnApp)
    }

    @Test("Window target is not own-app")
    func windowNotOwnApp() {
        let target = CaptureTarget.window(
            windowID: 123,
            title: "Window",
            owner: "App",
            width: 800,
            height: 600)
        #expect(!target.isOwnApp)
    }
}

// MARK: - Event Log Writer Lifecycle

@Suite("ScreencastEventLogWriter lifecycle")
struct ScreencastEventLogWriterTests {
    @Test("Writer creates events.json on flush")
    func flushCreatesFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = ScreencastEventLogWriter(
            sessionID: UUID(),
            startHostTimeUs: 0,
            directoryURL: dir,
            target: .display(displayID: 1, width: 1920, height: 1080))
        try writer.flush(events: [])

        let eventsURL = dir.appendingPathComponent("events.json")
        #expect(FileManager.default.fileExists(atPath: eventsURL.path))

        let data = try Data(contentsOf: eventsURL)
        let log = try JSONDecoder().decode(ScreencastEventLog.self, from: data)
        #expect(log.schemaVersion == ScreencastEventLog.currentSchemaVersion)
        #expect(log.events.isEmpty)
    }

    @Test("Writer with no events produces empty log")
    func emptyLog() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = ScreencastEventLogWriter(
            sessionID: UUID(),
            startHostTimeUs: 0,
            directoryURL: dir,
            target: .display(displayID: 1, width: 1920, height: 1080))
        #expect(writer.currentEvents().isEmpty)
    }
}
