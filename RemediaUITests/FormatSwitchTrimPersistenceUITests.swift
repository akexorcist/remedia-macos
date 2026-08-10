import XCTest

/// Regression coverage: trim used to reset when switching output format,
/// since `VideoSettings.trim`/`GifSettings.trim` were independent.
final class FormatSwitchTrimPersistenceUITests: XCTestCase {
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
    func testTrimSurvivesSwitchingOutputFormat() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_AUTOLOAD_MEDIA_PATH"] = fixtureURL.path
        app.launch()

        let startHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.startHandle").firstMatch
        XCTAssertTrue(startHandle.waitForExistence(timeout: 15))

        // Trim in from the start.
        let startCoord = startHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        startCoord.press(
            forDuration: 0.1, thenDragTo: startCoord.withOffset(CGVector(dx: 80, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )

        let trimmedX = startHandle.frame.midX

        // Switch output format to GIF, then back to MP4.
        let gifButton = app.radioButtons["GIF"]
        XCTAssertTrue(gifButton.waitForExistence(timeout: 5))
        gifButton.click()

        let afterGifX = startHandle.frame.midX
        XCTAssertEqual(
            afterGifX, trimmedX, accuracy: 2,
            "trim reset after switching to GIF (was \(trimmedX), now \(afterGifX))"
        )

        let mp4Button = app.radioButtons["MP4"]
        XCTAssertTrue(mp4Button.waitForExistence(timeout: 5))
        mp4Button.click()

        let afterMP4X = startHandle.frame.midX
        XCTAssertEqual(
            afterMP4X, trimmedX, accuracy: 2,
            "trim reset after switching back to MP4 (was \(trimmedX), now \(afterMP4X))"
        )
    }
}
