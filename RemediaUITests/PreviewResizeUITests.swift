import XCTest

/// Regression coverage for `ResizableVSplit`'s divider drag: it used to read
/// `DragGesture.translation` in `.local` space, but the divider moves as the
/// pane resizes, so the reference frame shifted mid-drag. Fixed by using
/// `location` in a stable, named coordinate space instead.
///
/// Measures the divider's own frame, not the top pane's — the pane's plain
/// container has no single accessibility element covering its full bounds,
/// so its identifier lands on an arbitrary child instead.
final class PreviewResizeUITests: XCTestCase {
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

    /// The core invariant the coordinate-space bug violated: drag distance
    /// should map 1:1 to actual movement.
    @MainActor
    func testDraggingDividerMovesByDragDistance() throws {
        let app = launchAtEditorScreen()

        let divider = app.descendants(matching: .any)
            .matching(identifier: "resizableVSplit.divider").firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 15))

        let initialY = divider.frame.minY
        let dragDistance: CGFloat = 40

        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: dragDistance))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)

        let movedY = divider.frame.minY
        let actualDelta = movedY - initialY

        XCTAssertEqual(
            actualDelta, dragDistance, accuracy: 4,
            "divider moved \(actualDelta)pt for a \(dragDistance)pt drag — resize isn't tracking the mouse 1:1"
        )
    }

    /// The old `.local`-space bug drifted here instead of cancelling out
    /// cleanly, since each leg measured against an already-moved frame.
    @MainActor
    func testDraggingDividerRoundTripReturnsToOriginalPosition() throws {
        let app = launchAtEditorScreen()

        let divider = app.descendants(matching: .any)
            .matching(identifier: "resizableVSplit.divider").firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 15))

        let initialY = divider.frame.minY
        let dragDistance: CGFloat = 50

        let down = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        down.press(
            forDuration: 0.2, thenDragTo: down.withOffset(CGVector(dx: 0, dy: dragDistance)),
            withVelocity: .slow, thenHoldForDuration: 0.2
        )

        let up = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        up.press(
            forDuration: 0.2, thenDragTo: up.withOffset(CGVector(dx: 0, dy: -dragDistance)),
            withVelocity: .slow, thenHoldForDuration: 0.2
        )

        let finalY = divider.frame.minY

        XCTAssertEqual(
            finalY, initialY, accuracy: 4,
            "round-tripping the divider drifted from y=\(initialY) to y=\(finalY) instead of cancelling out"
        )
    }
}
