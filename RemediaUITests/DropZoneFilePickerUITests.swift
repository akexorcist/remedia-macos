import XCTest

/// Clicking the drop zone opens a native file picker as an alternative to
/// drag-and-drop, since XCUITest can't synthesize a real Finder drag either
/// — this is the one screen this app can exercise end-to-end without the
/// `UI_TEST_AUTOLOAD_MEDIA_PATH` bypass the other UI tests rely on.
final class DropZoneFilePickerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RemediaUITests/
            .deletingLastPathComponent() // media-converter/
            .appendingPathComponent("RemediaCore/Tests/RemediaCoreTests/Fixtures/sample_video.mp4")
    }

    @MainActor
    func testClickingDropZoneOpensFilePickerAndLoadsSelection() throws {
        let app = XCUIApplication()
        app.launch()

        let dropZone = app.descendants(matching: .any)
            .matching(identifier: "dropZone.tapArea").firstMatch
        XCTAssertTrue(dropZone.waitForExistence(timeout: 15))
        dropZone.click()

        // NSOpenPanel surfaces as a plain top-level window (identifier
        // "open-panel"), not an app.dialogs/.sheets element.
        let openPanel = app.windows["open-panel"]
        XCTAssertTrue(openPanel.waitForExistence(timeout: 5), "file picker didn't open")

        // Cmd+Shift+G ("Go to folder") is the standard way to type an
        // absolute path into an NSOpenPanel's column-view browser.
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToField = openPanel.textFields.firstMatch
        XCTAssertTrue(goToField.waitForExistence(timeout: 5))
        goToField.typeText(fixtureURL.path)
        app.typeKey(.enter, modifierFlags: [])

        let openButton = openPanel.buttons["OKButton"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        XCTAssertTrue(openButton.isEnabled, "Open button didn't enable after navigating to the fixture")
        openButton.click()

        let convertButton = app.buttons["Convert"]
        XCTAssertTrue(convertButton.waitForExistence(timeout: 15), "picking a file didn't reach the editor screen")
    }
}
