import XCTest

final class RecorderFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testRecorderPauseResumeStopAndCollapseFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--localcut-ui-test-recorder-harness"]
        app.launchEnvironment["LOCALCUT_UI_TEST_RECORDER_HARNESS"] = "1"
        app.terminate()
        app.launch()
        app.activate()

        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-harness").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-idle").exists)

        clickButton("uitest-start-recording", in: app)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-recording").exists)

        clickButton("uitest-pause-recording", in: app)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-paused").exists)

        clickButton("uitest-resume-recording", in: app)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-recording").exists)

        clickButton("uitest-stop-recording", in: app)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-recorder-state-stopped").exists)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-timeline-gap-3-0").exists)

        clickButton("uitest-collapse-gaps", in: app)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-timeline-gap-0-0").exists)
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-status-gaps-collapsed").exists)
    }

    @MainActor
    private func clickButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.exists)
        button.click()
    }

    @MainActor
    private func element(in app: XCUIApplication, identifiedBy identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
