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
            .deletingLastPathComponent() // remedia/
            .appendingPathComponent("RemediaCore/Tests/RemediaCoreTests/Fixtures/sample_video.mp4")
    }

    @MainActor
    private func launchAtEditorScreen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_AUTOLOAD_MEDIA_PATH"] = fixtureURL.path
        // Without this, a force-terminated app's window state gets saved
        // and restored on the next launch — across enough UI tests in one
        // run, stale windows pile up until XCUIElement queries start
        // matching several duplicate "Remedia" windows at once.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    /// A tap's label change reaches the accessibility tree a beat after
    /// `.click()` returns — asserting immediately raced the render on a
    /// loaded machine. Waits instead of reading `.label` synchronously.
    private func waitForLabel(_ element: XCUIElement, toEqual expected: String, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "expected label \"\(expected)\", got \"\(element.label)\""
        )
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

        waitForLabel(playPauseIcon, toEqual: "Pause")
        let seekXWhilePlaying1 = seekIndicator.frame.midX
        Thread.sleep(forTimeInterval: 1.0)
        let seekXWhilePlaying2 = seekIndicator.frame.midX
        XCTAssertNotEqual(
            seekXWhilePlaying1, seekXWhilePlaying2,
            "seek indicator didn't advance while playing"
        )

        // Pause and confirm it stops advancing.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        waitForLabel(playPauseIcon, toEqual: "Play")
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

        // Trimmed this close, playback can auto-stop before .click() even
        // returns (it blocks until the app reports idle, and the playback
        // loop keeps it busy the whole time) — so "Pause" may never be
        // observable here. The wait below for the stable "Play" it settles
        // back into already proves playback ran.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // Give it generous time to reach the (now nearby) trim end and
        // auto-stop on its own — real decode/playback pacing, so a slower
        // CI runner genuinely needs more wall-clock time than a local Mac,
        // not just more polling patience.
        let stopped = NSPredicate(format: "label == %@", "Play")
        let expectation = XCTNSPredicateExpectation(predicate: stopped, object: playPauseIcon)
        let result = XCTWaiter().wait(for: [expectation], timeout: 30)
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

        // Trim the end in, but only enough to finish within the auto-stop
        // wait's timeout below — not so tight that the remaining duration
        // is comparable to XCTNSPredicateExpectation's own startup latency
        // (empirically over a second): trimmed to ~30% remaining, the whole
        // play-to-auto-stop cycle measured well under that latency, so the
        // very first "Pause" poll below always arrived after the *second*
        // cycle had already finished and reverted back to "Play" — no
        // timeout fixes that, since nothing further changes once it's back
        // at that same stable end state. ~70% remaining leaves a wide
        // enough window that the "Pause" state is actually observable.
        let endCoord = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragIn = endHandle.frame.midX * 0.3
        endCoord.press(
            forDuration: 0.1, thenDragTo: endCoord.withOffset(CGVector(dx: -dragIn, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )
        let trimmedStartX = startHandle.frame.midX

        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let stopped = NSPredicate(format: "label == %@", "Play")
        let stoppedExpectation = XCTNSPredicateExpectation(predicate: stopped, object: playPauseIcon)
        XCTAssertEqual(
            XCTWaiter().wait(for: [stoppedExpectation], timeout: 30), .completed,
            "playback never auto-stopped at the trim end"
        )
        // Play again — should replay from trim.start, not resume near the
        // end. Neither an immediate read after .click() (proven unreliable
        // earlier in this file — can catch a stale pre-click render) nor
        // waiting for a stable "Pause" state via XCTNSPredicateExpectation
        // (its own polling overhead is comparable to seconds of real
        // playback, drifting the check well past trim.start even when
        // correct) works here. A short fixed sleep is the middle ground:
        // long enough to guarantee at least one fresh post-click render,
        // short enough that genuine playback can only have drifted a few
        // frames from trim.start.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(
            seekIndicator.frame.midX, trimmedStartX, accuracy: 40,
            "replay didn't restart from trim.start"
        )

        // Stop playback so the app isn't left playing when the test ends.
        playPauseIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
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
