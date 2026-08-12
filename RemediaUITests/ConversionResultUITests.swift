import XCTest

/// Converts the sample fixture end-to-end and verifies the completed screen:
/// a rendered result player, duration/file-size overlay, and the
/// Back/Start Over/Save button row. Bypasses drag-and-drop file loading via
/// the `UI_TEST_AUTOLOAD_MEDIA_PATH` launch-environment hook in
/// `DropZoneView`.
final class ConversionResultUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RemediaUITests/
            .deletingLastPathComponent() // remedia/
            .appendingPathComponent("RemediaCore/Tests/RemediaCoreTests/Fixtures/sample_video.mp4")
    }

    @MainActor
    func testConvertingSampleVideoShowsResultPreviewScreen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_AUTOLOAD_MEDIA_PATH"] = fixtureURL.path
        // Without this, a force-terminated app's window state gets saved
        // and restored on the next launch — across enough UI tests in one
        // run, stale windows pile up until XCUIElement queries start
        // matching several duplicate "Remedia" windows at once.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let convertButton = app.buttons["Convert"]
        XCTAssertTrue(convertButton.waitForExistence(timeout: 15))
        convertButton.click()

        let durationLabel = app.descendants(matching: .any)
            .matching(identifier: "completedScreen.duration").firstMatch
        XCTAssertTrue(durationLabel.waitForExistence(timeout: 30), "conversion didn't reach the completed screen in time")

        let fileSizeLabel = app.descendants(matching: .any)
            .matching(identifier: "completedScreen.fileSize").firstMatch
        XCTAssertTrue(fileSizeLabel.exists, "expected a file-size label over the result preview")
        XCTAssertFalse((durationLabel.value as? String ?? "").isEmpty)
        XCTAssertFalse((fileSizeLabel.value as? String ?? "").isEmpty)

        XCTAssertTrue(app.buttons["Back"].exists)
        XCTAssertTrue(app.buttons["Start Over"].exists)
        XCTAssertTrue(app.buttons["Save"].exists)
    }

    @MainActor
    func testResultPlayPauseIconFadesInOnHoverAndOutOnExit() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_AUTOLOAD_MEDIA_PATH"] = fixtureURL.path
        // Without this, a force-terminated app's window state gets saved
        // and restored on the next launch — across enough UI tests in one
        // run, stale windows pile up until XCUIElement queries start
        // matching several duplicate "Remedia" windows at once.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let convertButton = app.buttons["Convert"]
        XCTAssertTrue(convertButton.waitForExistence(timeout: 30))
        convertButton.click()

        let playPauseIcon = app.descendants(matching: .any)
            .matching(identifier: "resultPlayer.playPauseIcon").firstMatch
        XCTAssertTrue(playPauseIcon.waitForExistence(timeout: 60), "conversion didn't reach the completed screen in time")

        let backButton = app.buttons["Back"]
        XCTAssertTrue(backButton.exists)

        // No "hidden by default" assertion here: .hover() moves the real OS
        // cursor, so the icon's state at launch depends on wherever the
        // physical cursor already is, outside this test's control.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let visible = NSPredicate(format: "value == %@", "visible")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: visible, object: playPauseIcon)], timeout: 5),
            .completed, "icon didn't fade in while the cursor is over the result preview"
        )

        // Back sits well outside the preview area — hovering it moves the
        // cursor off the preview entirely, the same as a real mouse exit.
        backButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let hidden = NSPredicate(format: "value == %@", "hidden")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: playPauseIcon)], timeout: 5),
            .completed, "icon didn't fade out after the cursor left the result preview"
        )
    }

    @MainActor
    func testBackButtonReturnsToEditorScreen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_AUTOLOAD_MEDIA_PATH"] = fixtureURL.path
        // Without this, a force-terminated app's window state gets saved
        // and restored on the next launch — across enough UI tests in one
        // run, stale windows pile up until XCUIElement queries start
        // matching several duplicate "Remedia" windows at once.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let convertButton = app.buttons["Convert"]
        XCTAssertTrue(convertButton.waitForExistence(timeout: 15))
        convertButton.click()

        let durationLabel = app.descendants(matching: .any)
            .matching(identifier: "completedScreen.duration").firstMatch
        XCTAssertTrue(durationLabel.waitForExistence(timeout: 30), "conversion didn't reach the completed screen in time")

        app.buttons["Back"].click()

        XCTAssertTrue(convertButton.waitForExistence(timeout: 5), "Back didn't return to the editor screen")
        XCTAssertFalse(durationLabel.exists, "completed screen's result info should be gone after Back")
    }

    @MainActor
    func testStartOverButtonReturnsToDropZoneScreen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_AUTOLOAD_MEDIA_PATH"] = fixtureURL.path
        // Without this, a force-terminated app's window state gets saved
        // and restored on the next launch — across enough UI tests in one
        // run, stale windows pile up until XCUIElement queries start
        // matching several duplicate "Remedia" windows at once.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let convertButton = app.buttons["Convert"]
        XCTAssertTrue(convertButton.waitForExistence(timeout: 15))
        convertButton.click()

        let durationLabel = app.descendants(matching: .any)
            .matching(identifier: "completedScreen.duration").firstMatch
        XCTAssertTrue(durationLabel.waitForExistence(timeout: 30), "conversion didn't reach the completed screen in time")

        app.buttons["Start Over"].click()

        // DropZoneView's autoload hook is one-shot per process (see its own
        // comment), so unlike the very first launch it won't re-fire and
        // race past this screen here.
        let dropZone = app.descendants(matching: .any)
            .matching(identifier: "dropZone.tapArea").firstMatch
        XCTAssertTrue(dropZone.waitForExistence(timeout: 5), "Start Over didn't return to the drop-zone screen")
        XCTAssertFalse(convertButton.exists, "editor screen's Convert button should be gone after Start Over")
    }
}
