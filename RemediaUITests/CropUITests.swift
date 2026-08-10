import XCTest

/// Coverage for `CropOverlayView` (freeform crop rect + resize handles) and
/// `CropPresetsView` (aspect presets, orientation toggle, Original/Free crop
/// modes). Bypasses drag-and-drop file loading via the
/// `UI_TEST_AUTOLOAD_MEDIA_PATH` launch-environment hook in `DropZoneView`.
/// The fixture is 320x240 (4:3).
final class CropUITests: XCTestCase {
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

    private func aspectRatio(of frame: CGRect) -> CGFloat {
        max(frame.width, frame.height) / min(frame.width, frame.height)
    }

    private func cropRect(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "cropOverlay.rect").firstMatch
    }

    @MainActor
    func testSelectingSquarePresetProducesSquareCropRect() throws {
        let app = launchAtEditorScreen()

        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        XCTAssertEqual(rect.frame.width, rect.frame.height, accuracy: 2, "1:1 preset should produce a square crop rect")
    }

    @MainActor
    func testSelecting16by9PresetProducesWidescreenCropRect() throws {
        let app = launchAtEditorScreen()

        let widescreenButton = app.radioButtons["16:9"]
        XCTAssertTrue(widescreenButton.waitForExistence(timeout: 15))
        widescreenButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(rect.frame.width, rect.frame.height, "16:9 landscape crop should be wider than tall")
        XCTAssertEqual(aspectRatio(of: rect.frame), 16.0 / 9.0, accuracy: 0.05)
    }

    /// "Original" (crop off) and "Free" (crop on, no fixed shape) both leave
    /// `viewModel.crop == nil`, so the overlay's actual drawability — not
    /// just the rect's absence — is what has to differ between them.
    @MainActor
    func testOriginalOptionClearsCropAndDisablesDrawing() throws {
        let app = launchAtEditorScreen()

        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))

        let originalButton = app.radioButtons["Original"]
        XCTAssertTrue(originalButton.waitForExistence(timeout: 5))
        originalButton.click()

        XCTAssertFalse(rect.waitForExistence(timeout: 2), "selecting Original should clear the crop overlay")

        let drawArea = app.descendants(matching: .any).matching(identifier: "cropOverlay.drawArea").firstMatch
        XCTAssertTrue(drawArea.waitForExistence(timeout: 5))
        let start = drawArea.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        start.press(
            forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 40)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )
        XCTAssertFalse(rect.waitForExistence(timeout: 2), "dragging in the preview shouldn't start a crop while Original is selected")
    }

    @MainActor
    func testDefaultStateIsOriginalCropDisabled() throws {
        let app = launchAtEditorScreen()

        let originalButton = app.radioButtons["Original"]
        XCTAssertTrue(originalButton.waitForExistence(timeout: 15))
        XCTAssertTrue(isChecked(originalButton), "Original should be selected by default, before any preset is touched")

        let drawArea = app.descendants(matching: .any).matching(identifier: "cropOverlay.drawArea").firstMatch
        XCTAssertTrue(drawArea.waitForExistence(timeout: 5))
        let rect = cropRect(in: app)
        XCTAssertFalse(rect.waitForExistence(timeout: 2))

        let start = drawArea.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        start.press(
            forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 40)),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )
        XCTAssertFalse(rect.waitForExistence(timeout: 2), "dragging on the freshly loaded preview shouldn't start a crop while Original is the default")
    }

    /// Switching to Free from an existing preset should only drop the ratio
    /// constraint, not hide or move the rect.
    @MainActor
    func testFreeOptionKeepsExistingRectVisible() throws {
        let app = launchAtEditorScreen()

        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        let squareFrame = rect.frame

        app.radioButtons["Free"].click()

        XCTAssertTrue(rect.waitForExistence(timeout: 2), "selecting Free shouldn't hide the existing crop rect")
        XCTAssertEqual(rect.frame, squareFrame, "switching to Free shouldn't move or resize the existing rect, only drop its ratio constraint")
    }

    /// Matching a named preset only happens via direct selection — Free
    /// right after "1:1" (still exactly square) shouldn't snap back to "1:1".
    @MainActor
    func testFreeStaysSelectedEvenWhenRatioExactlyMatchesAPreset() throws {
        let app = launchAtEditorScreen()

        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()

        let freeButton = app.radioButtons["Free"]
        freeButton.click()

        XCTAssertTrue(isChecked(freeButton), "Free should stay selected")
        XCTAssertFalse(isChecked(squareButton), "1:1 shouldn't reselect itself just because the rect happens to still be exactly square")
    }

    /// Selecting Free with no crop active yet should show a default 5:4
    /// rect immediately, not require a manual draw.
    @MainActor
    func testFreeOptionShowsDefaultRectWhenNoneExists() throws {
        let app = launchAtEditorScreen()

        let rect = cropRect(in: app)
        XCTAssertFalse(rect.waitForExistence(timeout: 2))

        let freeButton = app.radioButtons["Free"]
        XCTAssertTrue(freeButton.waitForExistence(timeout: 15))
        freeButton.click()

        XCTAssertTrue(rect.waitForExistence(timeout: 5), "selecting Free should show a default crop rect, not require a manual draw")
        XCTAssertGreaterThan(rect.frame.width, rect.frame.height, "the 5:4 default should be landscape")
        XCTAssertEqual(aspectRatio(of: rect.frame), 5.0 / 4.0, accuracy: 0.05, "Free's default shape should be 5:4")
    }

    /// Regression: orientation used to swap width/height in place, which a
    /// wide-enough rect couldn't survive without clamping toward square.
    /// It now re-derives a fresh, correctly-fitted rect instead.
    @MainActor
    func testSwitchingToPortraitAfterWidescreenPresetPreservesAspectRatio() throws {
        let app = launchAtEditorScreen()

        let widescreenButton = app.radioButtons["16:9"]
        XCTAssertTrue(widescreenButton.waitForExistence(timeout: 15))
        widescreenButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))

        let portraitButton = app.radioButtons["Portrait"]
        XCTAssertTrue(portraitButton.waitForExistence(timeout: 5))
        portraitButton.click()

        let portraitFrame = rect.frame
        XCTAssertGreaterThan(portraitFrame.height, portraitFrame.width, "Portrait orientation should be taller than wide")
        XCTAssertEqual(
            aspectRatio(of: portraitFrame), 16.0 / 9.0, accuracy: 0.05,
            "orientation swap should preserve the 16:9 ratio, not collapse toward square"
        )
    }

    /// Orientation-selection round trip: switching Landscape → Portrait →
    /// Landscape again should land back on a widescreen rect, not drift or
    /// get stuck — exercises the toggle in both directions, not just one.
    @MainActor
    func testOrientationRoundTripsBackToLandscape() throws {
        let app = launchAtEditorScreen()

        let fourByThreeButton = app.radioButtons["4:3"]
        XCTAssertTrue(fourByThreeButton.waitForExistence(timeout: 15))
        fourByThreeButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        let landscapeFrame = rect.frame
        XCTAssertGreaterThan(landscapeFrame.width, landscapeFrame.height)

        let portraitButton = app.radioButtons["Portrait"]
        XCTAssertTrue(portraitButton.waitForExistence(timeout: 5))
        portraitButton.click()
        XCTAssertGreaterThan(rect.frame.height, rect.frame.width, "Portrait should be taller than wide")

        let landscapeButton = app.radioButtons["Landscape"]
        XCTAssertTrue(landscapeButton.waitForExistence(timeout: 5))
        landscapeButton.click()

        let backToLandscapeFrame = rect.frame
        XCTAssertGreaterThan(backToLandscapeFrame.width, backToLandscapeFrame.height, "should be widescreen again after round-tripping back to Landscape")
        XCTAssertEqual(aspectRatio(of: backToLandscapeFrame), 4.0 / 3.0, accuracy: 0.05)
    }

    @MainActor
    func testOrientationDisabledForSquareCrop() throws {
        let app = launchAtEditorScreen()

        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))

        let portraitButton = app.radioButtons["Portrait"]
        XCTAssertTrue(portraitButton.waitForExistence(timeout: 5))
        XCTAssertFalse(portraitButton.isEnabled, "orientation toggle should be disabled for a square (1:1) crop")
    }

    /// Regression: preset matching tolerates only floating-point noise, not
    /// real pixel differences — a slight nudge off exact square should fall
    /// back to Free, not stay mislabeled "1:1".
    @MainActor
    func testResizingSlightlyOffSquareFallsBackToFreeWithOrientationDisabled() throws {
        let app = launchAtEditorScreen()

        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        let initialWidth = rect.frame.width

        // ~1% wider via the bottom-right corner — outside the exact-match
        // tolerance. Expressed as a fraction of the rect's on-screen size
        // so it scales with whatever window size this runs at.
        let start = rect.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        let dragDelta = max(initialWidth * 0.01, 2)
        start.press(
            forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: dragDelta, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.2
        )

        XCTAssertTrue(isChecked(app.radioButtons["Free"]), "a resize off exact 1:1 should fall back to Free, not stay matched as 1:1")

        let portraitButton = app.radioButtons["Portrait"]
        XCTAssertFalse(portraitButton.isEnabled, "orientation toggle should stay disabled once the crop reads as Free")
    }

    /// "Free" has no named shape to flip, so the toggle is disabled even
    /// though the default 5:4 rect itself is non-square — but it should
    /// still correctly *show* Landscape as the current orientation.
    @MainActor
    func testOrientationDisabledForFreeCropButStillReflectsCurrentOrientation() throws {
        let app = launchAtEditorScreen()

        let freeButton = app.radioButtons["Free"]
        XCTAssertTrue(freeButton.waitForExistence(timeout: 15))
        freeButton.click()

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(rect.frame.width, rect.frame.height, "Free's default 5:4 shape should be landscape")

        let landscapeButton = app.radioButtons["Landscape"]
        let portraitButton = app.radioButtons["Portrait"]
        XCTAssertTrue(landscapeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(isChecked(landscapeButton), "orientation toggle should still reflect the rect's actual (landscape) orientation")
        XCTAssertFalse(landscapeButton.isEnabled, "orientation toggle should be disabled while Free is selected")
        XCTAssertFalse(portraitButton.isEnabled)
    }

    /// Drags the bottom-right handle outward; the opposite corner should
    /// stay anchored. Started from a point on the *rect* element (99%
    /// toward its corner) rather than the handle's own `.coordinate(...)`,
    /// which resolves to a stale position despite `handle.frame` reporting
    /// correctly (same AX-bridging staleness as `TrimScrubberSeekUITests`).
    @MainActor
    func testDraggingCornerHandleGrowsRectFromOppositeAnchor() throws {
        let app = launchAtEditorScreen()

        // 320x240 source: a 1:1 crop is height-limited (240x240), leaving
        // horizontal room to grow without hitting the source bounds.
        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()

        let rect = cropRect(in: app)
        let handle = app.descendants(matching: .any).matching(identifier: "cropOverlay.handle.bottomRight").firstMatch
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        XCTAssertTrue(handle.exists)

        let initialFrame = rect.frame
        let start = rect.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        let dragDelta: CGFloat = 60
        start.press(
            forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: dragDelta, dy: dragDelta)),
            withVelocity: .slow, thenHoldForDuration: 0.2
        )

        let resizedFrame = rect.frame
        XCTAssertEqual(
            resizedFrame.minX, initialFrame.minX, accuracy: 4,
            "the opposite (top-left) corner should stay anchored while resizing from bottom-right"
        )
        XCTAssertGreaterThan(
            resizedFrame.width, initialFrame.width + 10,
            "dragging the bottom-right handle outward should grow the crop rect's width"
        )
    }

    /// Segmented-control selection surfaces via `.value` (an `Int` 1/0) on
    /// this AX bridging, not `.isSelected`.
    private func isChecked(_ element: XCUIElement) -> Bool {
        (element.value as? Int) == 1
    }

    /// Once a resize drifts the rect off every preset's exact ratio, the
    /// segmented control should fall back to "Free" rather than leaving
    /// nothing highlighted — a ratio-less crop is exactly what "Free" means.
    @MainActor
    func testResizingAwayFromPresetRatioSelectsFree() throws {
        let app = launchAtEditorScreen()

        let squareButton = app.radioButtons["1:1"]
        XCTAssertTrue(squareButton.waitForExistence(timeout: 15))
        squareButton.click()
        XCTAssertTrue(isChecked(squareButton))

        let rect = cropRect(in: app)
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        let start = rect.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        start.press(
            forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.2
        )

        let freeButton = app.radioButtons["Free"]
        XCTAssertTrue(isChecked(freeButton), "resizing off the 1:1 ratio should fall back to Free being selected")
        XCTAssertFalse(isChecked(squareButton), "1:1 shouldn't stay selected once the rect no longer matches that ratio")
    }
}
