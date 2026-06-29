import XCTest

final class RecorderFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testRecorderPauseResumeStopAndCollapseFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--localcut-ui-test-recorder-harness"]
        app.launchEnvironment["LOCALCUT_UI_TEST_RECORDER_HARNESS"] = "1"
        app.terminate()
        app.launch()
        app.activate()

        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-harness").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-idle").exists)

        let recorderShortcutModifiers: XCUIElement.KeyModifierFlags = [.command, .option, .control]

        app.typeKey("1", modifierFlags: recorderShortcutModifiers)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-recording").waitForExistence(timeout: 2))

        app.typeKey("2", modifierFlags: recorderShortcutModifiers)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-paused").waitForExistence(timeout: 2))

        app.typeKey("3", modifierFlags: recorderShortcutModifiers)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-recording").waitForExistence(timeout: 2))

        app.typeKey("4", modifierFlags: recorderShortcutModifiers)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-stopped").waitForExistence(timeout: 2))
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-timeline-gap-3-0").waitForExistence(timeout: 2))

        app.typeKey("5", modifierFlags: recorderShortcutModifiers)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-timeline-gap-0-0").waitForExistence(timeout: 2))
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-status-gaps-collapsed").waitForExistence(timeout: 2))
    }

    private func element(in app: XCUIApplication, identifiedBy identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
