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
            height: 600,
            frame: CGRect(x: 10, y: 20, width: 800, height: 600))
        #expect(!target.isOwnApp)
    }
}

@Suite("Screencast event coordinate mapping")
struct ScreencastEventCoordinateMapperTests {
    @Test("Non-own app target records mouse events in display coordinate space")
    func appTargetMapsDisplaySpace() {
        let target = CaptureTarget.application(
            processID: 99,
            bundleIdentifier: "com.example.Other",
            name: "Other",
            displayID: 7,
            width: 1920,
            height: 1080)

        let position = ScreencastEventCoordinateMapper.normalizedPosition(
            target: target,
            captureRegion: nil,
            monitorSource: .globalTarget,
            screenLocation: CGPoint(x: 960, y: 540),
            locationInWindow: .zero,
            windowSize: nil,
            screenFrameProvider: { displayID in
                displayID == 7 ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : nil
            })

        #expect(position == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("Window target maps through captured window frame and drops off-window events")
    func windowTargetUsesWindowFrame() {
        let target = CaptureTarget.window(
            windowID: 42,
            title: "Editor",
            owner: "Other",
            width: 800,
            height: 600,
            frame: CGRect(x: 100, y: 200, width: 800, height: 600))

        let inside = ScreencastEventCoordinateMapper.normalizedPosition(
            target: target,
            captureRegion: nil,
            monitorSource: .globalTarget,
            screenLocation: CGPoint(x: 500, y: 500),
            locationInWindow: .zero,
            windowSize: nil,
            screenFrameProvider: { _ in nil })
        let outside = ScreencastEventCoordinateMapper.normalizedPosition(
            target: target,
            captureRegion: nil,
            monitorSource: .globalTarget,
            screenLocation: CGPoint(x: 50, y: 500),
            locationInWindow: CGPoint(x: 400, y: 300),
            windowSize: CGSize(width: 800, height: 600),
            screenFrameProvider: { _ in nil })

        #expect(inside == CGPoint(x: 0.5, y: 0.5))
        #expect(outside == nil)
    }

    @Test("Display region maps relative to the captured region")
    func displayRegionMapsRelativeToRegion() throws {
        let region = try #require(CaptureRegion(
            displayID: 7,
            selectionInScreen: CGRect(x: 100, y: 200, width: 400, height: 300),
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            displayPixelWidth: 1920,
            displayPixelHeight: 1080))

        let position = ScreencastEventCoordinateMapper.normalizedPosition(
            target: .display(displayID: 7, width: 1920, height: 1080),
            captureRegion: region,
            monitorSource: .globalTarget,
            screenLocation: CGPoint(x: 300, y: 350),
            locationInWindow: .zero,
            windowSize: nil,
            screenFrameProvider: { displayID in
                displayID == 7 ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : nil
            })

        #expect(position == CGPoint(x: 0.5, y: 0.5))
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
