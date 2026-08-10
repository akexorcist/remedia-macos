import XCTest

/// Editor-screen preview play/pause: tapping toggles playback, the seek
/// indicator advances while playing and stops advancing when paused, and
/// playback stops at the selected trim end. Bypasses drag-and-drop file
/// loading via the `UI_TEST_AUTOLOAD_MEDIA_PATH` launch-environment hook in
/// `DropZoneView`.
final class PreviewPlaybackUITests: XCTestCase {
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
    private func launchAtEditorScreen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_AUTOLOAD_MEDIA_PATH"] = fixtureURL.path
        app.launch()
        return app
    }

    @MainActor
    func testTappingPreviewPlaysAndPausesWithSeekIndicatorFollowing() throws {
        let app = launchAtEditorScreen()

        let playPauseIcon = app.descendants(matching: .any)
            .matching(identifier: "previewPlayer.playPauseIcon").firstMatch
        let seekIndicator = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.seekIndicator").firstMatch
        XCTAssertTrue(playPauseIcon.waitForExistence(timeout: 15))
        XCTAssertTrue(seekIndicator.exists)

        XCTAssertEqual(playPauseIcon.label, "Play")

        // Tap at the icon's own coordinates: it has allowsHitTesting(false)
        // so the click falls through to the tap gesture on the preview
        // area behind it.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertEqual(playPauseIcon.label, "Pause")
        let seekXWhilePlaying1 = seekIndicator.frame.midX
        Thread.sleep(forTimeInterval: 1.0)
        let seekXWhilePlaying2 = seekIndicator.frame.midX
        XCTAssertNotEqual(
            seekXWhilePlaying1, seekXWhilePlaying2,
            "seek indicator didn't advance while playing"
        )

        // Pause and confirm it stops advancing.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(playPauseIcon.label, "Play")
        let seekXAfterPause1 = seekIndicator.frame.midX
        Thread.sleep(forTimeInterval: 0.5)
        let seekXAfterPause2 = seekIndicator.frame.midX
        XCTAssertEqual(
            seekXAfterPause1, seekXAfterPause2,
            "seek indicator kept moving after pausing"
        )
    }

    @MainActor
    func testPlaybackStopsAtTrimEnd() throws {
        let app = launchAtEditorScreen()

        let playPauseIcon = app.descendants(matching: .any)
            .matching(identifier: "previewPlayer.playPauseIcon").firstMatch
        let endHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.endHandle").firstMatch
        let seekIndicator = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.seekIndicator").firstMatch
        XCTAssertTrue(playPauseIcon.waitForExistence(timeout: 15))
        XCTAssertTrue(endHandle.exists)

        // Trim the end in close to the start so playback reaches it quickly.
        let endCoord = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragIn = endHandle.frame.midX * 0.7
        endCoord.press(
            forDuration: 0.1, thenDragTo: endCoord.withOffset(CGVector(dx: -dragIn, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )
        let trimmedEndX = endHandle.frame.midX

        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(playPauseIcon.label, "Pause")

        // Give it generous time to reach the (now nearby) trim end and
        // auto-stop on its own.
        let stopped = NSPredicate(format: "label == %@", "Play")
        let expectation = XCTNSPredicateExpectation(predicate: stopped, object: playPauseIcon)
        let result = XCTWaiter().wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "playback never auto-stopped at the trim end")

        XCTAssertEqual(
            seekIndicator.frame.midX, trimmedEndX, accuracy: 6,
            "seek indicator didn't settle at the trimmed end position"
        )
    }

    @MainActor
    func testPlayingAgainAfterEndReplaysFromTrimStart() throws {
        let app = launchAtEditorScreen()

        let playPauseIcon = app.descendants(matching: .any)
            .matching(identifier: "previewPlayer.playPauseIcon").firstMatch
        let startHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.startHandle").firstMatch
        let endHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.endHandle").firstMatch
        let seekIndicator = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.seekIndicator").firstMatch
        XCTAssertTrue(playPauseIcon.waitForExistence(timeout: 15))
        XCTAssertTrue(endHandle.exists)

        // Trim the end in close so playback finishes quickly.
        let endCoord = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragIn = endHandle.frame.midX * 0.7
        endCoord.press(
            forDuration: 0.1, thenDragTo: endCoord.withOffset(CGVector(dx: -dragIn, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )
        let trimmedStartX = startHandle.frame.midX

        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let stopped = NSPredicate(format: "label == %@", "Play")
        let stoppedExpectation = XCTNSPredicateExpectation(predicate: stopped, object: playPauseIcon)
        XCTAssertEqual(
            XCTWaiter().wait(for: [stoppedExpectation], timeout: 10), .completed,
            "playback never auto-stopped at the trim end"
        )

        // Play again — should replay from trim.start, not resume near the end.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(playPauseIcon.label, "Pause")
        XCTAssertEqual(
            seekIndicator.frame.midX, trimmedStartX, accuracy: 6,
            "replay didn't restart from trim.start"
        )
    }

    @MainActor
    func testPlayPauseIconFadesInOnHoverAndOutOnExit() throws {
        let app = launchAtEditorScreen()

        let playPauseIcon = app.descendants(matching: .any)
            .matching(identifier: "previewPlayer.playPauseIcon").firstMatch
        let convertButton = app.buttons["Convert"]
        XCTAssertTrue(playPauseIcon.waitForExistence(timeout: 30))
        XCTAssertTrue(convertButton.exists)

        // No "hidden by default" assertion here: .hover() moves the real OS
        // cursor, so the icon's state at launch depends on wherever the
        // physical cursor already is, outside this test's control.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let visible = NSPredicate(format: "value == %@", "visible")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: visible, object: playPauseIcon)], timeout: 5),
            .completed, "icon didn't fade in while the cursor is over the preview"
        )

        // Convert is well outside the preview area — hovering it moves the
        // cursor off the preview entirely, the same as a real mouse exit.
        convertButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let hidden = NSPredicate(format: "value == %@", "hidden")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: playPauseIcon)], timeout: 5),
            .completed, "icon didn't fade out after the cursor left the preview"
        )
    }
}
