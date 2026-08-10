import XCTest

/// Reproduces a reported bug: after dragging the start/end trim handles,
/// the seek indicator could no longer be dragged.
///
/// Seek-drag targets are computed from the trim handles' own frames, not
/// `trimScrubber.selectedRange`'s — that element's accessibility frame
/// stays frozen at its initial width after trimming (a `Shape` accessibility-
/// bridging staleness, not a real rendering bug), while the handles report
/// correctly since they only change position.
final class TrimScrubberSeekUITests: XCTestCase {
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
        app.launch()
        return app
    }

    /// Midpoint between two elements' frames, as an offset from `from`'s own
    /// coordinate — avoids needing an absolute-point frame anchor.
    private func midpointCoordinate(from: XCUIElement, to: XCUIElement) -> XCUICoordinate {
        let anchor = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let deltaX = (to.frame.midX - from.frame.midX) / 2
        return anchor.withOffset(CGVector(dx: deltaX, dy: 0))
    }

    @MainActor
    func testSeekingStillWorksAfterTrimmingStartAndEnd() throws {
        let app = launchAtEditorScreen()

        let startHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.startHandle").firstMatch
        let endHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.endHandle").firstMatch
        let seekIndicator = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.seekIndicator").firstMatch

        XCTAssertTrue(startHandle.waitForExistence(timeout: 15))
        XCTAssertTrue(endHandle.exists)
        XCTAssertTrue(seekIndicator.exists)

        // Trim in from both ends, same gesture style as the reported repro.
        let startCoord = startHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        startCoord.press(
            forDuration: 0.1, thenDragTo: startCoord.withOffset(CGVector(dx: 40, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )

        let endCoord = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        endCoord.press(
            forDuration: 0.1, thenDragTo: endCoord.withOffset(CGVector(dx: -40, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )

        let seekBeforeX = seekIndicator.frame.midX

        // Seek by dragging at the midpoint between the two (now-trimmed)
        // handles, computed from their own frames.
        let rangeCoord = midpointCoordinate(from: startHandle, to: endHandle)
        rangeCoord.press(
            forDuration: 0.1, thenDragTo: rangeCoord.withOffset(CGVector(dx: 15, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )

        let seekAfterX = seekIndicator.frame.midX

        XCTAssertNotEqual(
            seekBeforeX, seekAfterX,
            "seek indicator didn't move after trimming start/end and dragging within the selected range"
        )
    }

    /// Same repro, trimmed close enough that the two handles might fully
    /// cover the remaining gap, leaving no exposed area for the seek gesture.
    @MainActor
    func testSeekingWorksWithVeryNarrowTrimRange() throws {
        let app = launchAtEditorScreen()

        let startHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.startHandle").firstMatch
        let endHandle = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.endHandle").firstMatch
        let seekIndicator = app.descendants(matching: .any)
            .matching(identifier: "trimScrubber.seekIndicator").firstMatch

        XCTAssertTrue(startHandle.waitForExistence(timeout: 15))
        XCTAssertTrue(endHandle.exists)

        // Scaled off the actual track width so this can't over-drag past
        // the midpoint on a narrower window.
        let initialGap = endHandle.frame.midX - startHandle.frame.midX
        let dragIn = initialGap * 0.45

        let startCoord = startHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        startCoord.press(
            forDuration: 0.1, thenDragTo: startCoord.withOffset(CGVector(dx: dragIn, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )

        let endCoord = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        endCoord.press(
            forDuration: 0.1, thenDragTo: endCoord.withOffset(CGVector(dx: -dragIn, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )

        let gapWidth = endHandle.frame.midX - startHandle.frame.midX
        XCTAssertGreaterThan(gapWidth, 0, "handles crossed — trim inputs need clamping")

        let seekBeforeX = seekIndicator.frame.midX

        let rangeCoord = midpointCoordinate(from: startHandle, to: endHandle)
        let dragDistance = min(5, gapWidth / 4)
        rangeCoord.press(
            forDuration: 0.1, thenDragTo: rangeCoord.withOffset(CGVector(dx: dragDistance, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )

        let seekAfterX = seekIndicator.frame.midX

        XCTAssertNotEqual(
            seekBeforeX, seekAfterX,
            "seek indicator didn't move with a very narrow trim range (gap=\(gapWidth)pt)"
        )
    }
}
