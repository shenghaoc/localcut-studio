import XCTest

/// XCUI coverage for timeline shortcut focus transitions. Pure unit tests in
/// `EditorKeyHandlerPolicyTests` cover key→action mapping only; the production
/// `TimelineView` test protects the marker popover's focus wiring.
final class TimelineFocusUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTextFieldKeepsSpaceAndMarkerKeys() {
        let app = launchHarness()
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-timeline-focus-harness").waitForExistence(timeout: 5))

        clickButton("uitest-focus-text", in: app)
        let field = app.textFields["uitest-marker-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()

        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(lastAction(in: app), "text-space")

        app.typeKey("m", modifierFlags: [])
        XCTAssertEqual(lastAction(in: app), "text-m")

        app.typeKey("m", modifierFlags: .shift)
        XCTAssertEqual(lastAction(in: app), "text-shift-m")
    }

    @MainActor
    func testTimelineReceivesShortcutsOnlyWhileFocused() {
        let app = launchHarness()
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-timeline-focus-harness").waitForExistence(timeout: 5))

        clickButton("uitest-focus-timeline", in: app)
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(lastAction(in: app), "timeline-space")

        app.typeKey("m", modifierFlags: [])
        XCTAssertEqual(lastAction(in: app), "timeline-m")

        clickButton("uitest-focus-text", in: app)
        app.textFields["uitest-marker-name-field"].click()
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(lastAction(in: app), "text-space")
    }

    @MainActor
    func testFocusRecoveryAfterLeavingTextField() {
        let app = launchHarness()
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-timeline-focus-harness").waitForExistence(timeout: 5))

        clickButton("uitest-focus-text", in: app)
        app.textFields["uitest-marker-name-field"].click()
        app.typeKey("m", modifierFlags: [])
        XCTAssertEqual(lastAction(in: app), "text-m")

        clickButton("uitest-focus-timeline", in: app)
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(lastAction(in: app), "timeline-space")
    }

    @MainActor
    func testRealTimelineMarkerRenameFieldKeepsShortcutsAndRestoresFocus() {
        let app = launchTimelineViewHarness()
        XCTAssertTrue(element(in: app, identifiedBy: "uitest-real-timeline-harness")
            .waitForExistence(timeout: 5))
        let markers = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Marker ")
        )
        XCTAssertTrue(markers.firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(markers.count, 1)

        app.typeKey("m", modifierFlags: .shift)
        let field = app.textFields["Name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeKey("m", modifierFlags: [])
        field.typeKey(" ", modifierFlags: [])
        field.typeKey("m", modifierFlags: .shift)
        XCTAssertEqual(field.value as? String, "m M")
        XCTAssertEqual(markers.count, 1)

        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        field.typeKey("x", modifierFlags: [])
        field.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        field.typeKey(XCUIKeyboardKey.forwardDelete.rawValue, modifierFlags: [])
        XCTAssertEqual(field.value as? String, "m ")
        XCTAssertEqual(markers.count, 1)

        app.buttons["Done"].click()
        app.typeKey("m", modifierFlags: [])
        XCTAssertTrue(markers.element(boundBy: 1).waitForExistence(timeout: 2))
        XCTAssertEqual(markers.count, 2)
    }

    @MainActor
    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "--localcut-ui-test-timeline-focus-harness"
        ]
        app.launchEnvironment["LOCALCUT_UI_TEST_TIMELINE_FOCUS_HARNESS"] = "1"
        app.terminate()
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func launchTimelineViewHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "--localcut-ui-test-timeline-view-harness"
        ]
        app.launchEnvironment["LOCALCUT_UI_TEST_TIMELINE_VIEW_HARNESS"] = "1"
        app.terminate()
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func lastAction(in app: XCUIApplication) -> String {
        let label = element(in: app, identifiedBy: "uitest-last-action")
        XCTAssertTrue(label.waitForExistence(timeout: 2))
        return label.value as? String ?? label.label
    }

    @MainActor
    private func clickButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        button.click()
    }

    @MainActor
    private func element(in app: XCUIApplication, identifiedBy identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
