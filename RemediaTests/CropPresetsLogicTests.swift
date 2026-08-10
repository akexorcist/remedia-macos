import XCTest
@testable import Remedia

final class CropPresetsLogicTests: XCTestCase {
    private let source4x3 = CGSize(width: 320, height: 240)

    // MARK: - matchedPreset

    func testMatchedPresetExactSquare() {
        let square = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertEqual(CropPresetsView.matchedPreset(for: square), "1:1")
    }

    func testMatchedPresetExactWidescreenLandscape() {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertEqual(CropPresetsView.matchedPreset(for: rect), "16:9")
    }

    func testMatchedPresetExactWidescreenPortraitStillMatchesByNormalizedRatio() {
        let rect = CGRect(x: 0, y: 0, width: 900, height: 1600)
        XCTAssertEqual(CropPresetsView.matchedPreset(for: rect), "16:9")
    }

    func testMatchedPresetExactStandard() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(CropPresetsView.matchedPreset(for: rect), "4:3")
    }

    func testMatchedPresetNearMissDoesNotMatch() {
        // 4:3 is 1.333..., this is 1.326 — a real ~0.5% difference, not
        // floating-point noise, so it must not be labeled "4:3".
        let rect = CGRect(x: 0, y: 0, width: 240, height: 181)
        XCTAssertNil(CropPresetsView.matchedPreset(for: rect))
    }

    func testMatchedPresetNilCrop() {
        XCTAssertNil(CropPresetsView.matchedPreset(for: nil))
    }

    func testMatchedPresetZeroSizeCrop() {
        XCTAssertNil(CropPresetsView.matchedPreset(for: .zero))
    }

    func testMatchedPresetFreeformRatioDoesNotMatchAnyPreset() {
        let rect = CGRect(x: 0, y: 0, width: 500, height: 333)
        XCTAssertNil(CropPresetsView.matchedPreset(for: rect))
    }

    // MARK: - presetRect

    func testPresetRectWidthLimitedWhenRatioWiderThanSource() {
        // 16:9 is wider than the 4:3 source, so width should hit the
        // source's own width and height should be derived from it.
        guard let rect = CropPresetsView.presetRect(ratio: 16.0 / 9.0, orientation: .landscape, sourceSize: source4x3) else {
            return XCTFail("expected a rect")
        }
        XCTAssertEqual(rect.width, source4x3.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, source4x3.width / (16.0 / 9.0), accuracy: 0.001)
    }

    func testPresetRectHeightLimitedWhenRatioNarrowerThanSource() {
        // 1:1 is narrower than the 4:3 source, so height should hit the
        // source's own height and width should be derived from it.
        guard let rect = CropPresetsView.presetRect(ratio: 1.0, orientation: .landscape, sourceSize: source4x3) else {
            return XCTFail("expected a rect")
        }
        XCTAssertEqual(rect.height, source4x3.height, accuracy: 0.001)
        XCTAssertEqual(rect.width, source4x3.height, accuracy: 0.001)
    }

    func testPresetRectIsCenteredInSource() {
        guard let rect = CropPresetsView.presetRect(ratio: 1.0, orientation: .landscape, sourceSize: source4x3) else {
            return XCTFail("expected a rect")
        }
        XCTAssertEqual(rect.midX, source4x3.width / 2, accuracy: 0.001)
        XCTAssertEqual(rect.midY, source4x3.height / 2, accuracy: 0.001)
    }

    func testPresetRectPortraitInvertsRatio() {
        guard let landscapeRect = CropPresetsView.presetRect(ratio: 16.0 / 9.0, orientation: .landscape, sourceSize: source4x3),
              let portraitRect = CropPresetsView.presetRect(ratio: 16.0 / 9.0, orientation: .portrait, sourceSize: source4x3)
        else {
            return XCTFail("expected both rects")
        }
        XCTAssertGreaterThan(landscapeRect.width, landscapeRect.height)
        XCTAssertGreaterThan(portraitRect.height, portraitRect.width)
        let landscapeRatio = max(landscapeRect.width, landscapeRect.height) / min(landscapeRect.width, landscapeRect.height)
        let portraitRatio = max(portraitRect.width, portraitRect.height) / min(portraitRect.width, portraitRect.height)
        XCTAssertEqual(landscapeRatio, portraitRatio, accuracy: 0.001)
    }

    func testPresetRectZeroSourceSizeReturnsNil() {
        XCTAssertNil(CropPresetsView.presetRect(ratio: 1.0, orientation: .landscape, sourceSize: .zero))
    }

    // MARK: - reoriented

    /// Regression: orientation used to swap width/height in place, which an
    /// edge-touching rect can't survive without clamping toward square.
    func testReorientedEdgeTouchingWidescreenDoesNotCollapseTowardSquare() {
        guard let landscape = CropPresetsView.presetRect(ratio: 16.0 / 9.0, orientation: .landscape, sourceSize: source4x3),
              let portrait = CropPresetsView.reoriented(landscape, to: .portrait, sourceSize: source4x3)
        else {
            return XCTFail("expected both rects")
        }
        XCTAssertGreaterThan(portrait.height, portrait.width)
        let ratio = max(portrait.width, portrait.height) / min(portrait.width, portrait.height)
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.01, "reorienting should preserve 16:9, not collapse toward square")
    }

    func testReorientedZeroSizeCropReturnsNil() {
        XCTAssertNil(CropPresetsView.reoriented(.zero, to: .portrait, sourceSize: source4x3))
    }

    // MARK: - defaultFreeRect

    func testDefaultFreeRectIsLandscapeFiveByFour() {
        guard let rect = CropPresetsView.defaultFreeRect(sourceSize: source4x3) else {
            return XCTFail("expected a rect")
        }
        XCTAssertGreaterThan(rect.width, rect.height)
        XCTAssertEqual(rect.width / rect.height, 5.0 / 4.0, accuracy: 0.001)
    }

    func testDefaultFreeRectIsPaddedSmallerThanTheFittedShape() {
        guard let fitted = CropPresetsView.presetRect(ratio: 5.0 / 4.0, orientation: .landscape, sourceSize: source4x3),
              let padded = CropPresetsView.defaultFreeRect(sourceSize: source4x3)
        else {
            return XCTFail("expected both rects")
        }
        XCTAssertEqual(padded.width, fitted.width * 0.9, accuracy: 0.001)
        XCTAssertEqual(padded.height, fitted.height * 0.9, accuracy: 0.001)
    }

    // MARK: - orientation(of:)

    func testOrientationLandscapeWhenWiderThanTall() {
        XCTAssertEqual(CropPresetsView.orientation(of: CGRect(x: 0, y: 0, width: 100, height: 50)), .landscape)
    }

    func testOrientationPortraitWhenTallerThanWide() {
        XCTAssertEqual(CropPresetsView.orientation(of: CGRect(x: 0, y: 0, width: 50, height: 100)), .portrait)
    }

    func testOrientationSquareCountsAsLandscape() {
        XCTAssertEqual(CropPresetsView.orientation(of: CGRect(x: 0, y: 0, width: 100, height: 100)), .landscape)
    }

    func testOrientationNilCropCountsAsLandscape() {
        XCTAssertEqual(CropPresetsView.orientation(of: nil), .landscape)
    }

    // MARK: - selection(afterSelecting:)

    func testSelectingOriginalDisablesCroppingAndClearsRect() {
        let result = CropPresetsView.selection(
            afterSelecting: "Original", currentOrientation: .landscape,
            sourceSize: source4x3, existingCrop: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertNil(result.selectedShape, "Original doesn't change selectedCropShape — isCropDisabled drives its display")
        XCTAssertTrue(result.isCropDisabled)
        XCTAssertNil(result.crop)
    }

    func testSelectingFreeWithNoExistingCropUsesDefault() {
        let result = CropPresetsView.selection(
            afterSelecting: "Free", currentOrientation: .landscape, sourceSize: source4x3, existingCrop: nil
        )
        XCTAssertEqual(result.selectedShape, "Free")
        XCTAssertFalse(result.isCropDisabled)
        XCTAssertEqual(result.crop, CropPresetsView.defaultFreeRect(sourceSize: source4x3))
    }

    func testSelectingFreeWithExistingCropKeepsItUnchanged() {
        let existing = CGRect(x: 10, y: 10, width: 123, height: 87)
        let result = CropPresetsView.selection(
            afterSelecting: "Free", currentOrientation: .landscape, sourceSize: source4x3, existingCrop: existing
        )
        XCTAssertEqual(result.selectedShape, "Free")
        XCTAssertEqual(result.crop, existing)
    }

    func testSelectingNamedPresetComputesThatShape() {
        let result = CropPresetsView.selection(
            afterSelecting: "1:1", currentOrientation: .landscape, sourceSize: source4x3, existingCrop: nil
        )
        XCTAssertEqual(result.selectedShape, "1:1")
        XCTAssertFalse(result.isCropDisabled)
        XCTAssertEqual(CropPresetsView.matchedPreset(for: result.crop), "1:1")
    }

    // MARK: - driftedSelection

    func testDriftedSelectionStaysOnPresetWhenRatioStillMatches() {
        let shape = CropPresetsView.driftedSelection(currentShape: "1:1", crop: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(shape, "1:1")
    }

    func testDriftedSelectionFallsBackToFreeWhenRatioNoLongerMatches() {
        let shape = CropPresetsView.driftedSelection(currentShape: "1:1", crop: CGRect(x: 0, y: 0, width: 200, height: 260))
        XCTAssertEqual(shape, "Free")
    }

    /// The behavior this whole feature request was about: Free never
    /// auto-advances to a named preset, even if the rect exactly matches one.
    func testDriftedSelectionNeverAdvancesFromFreeToAPreset() {
        let shape = CropPresetsView.driftedSelection(currentShape: "Free", crop: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(shape, "Free")
    }

    func testDriftedSelectionLeavesOriginalUntouched() {
        let shape = CropPresetsView.driftedSelection(currentShape: "Original", crop: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(shape, "Original")
    }
}
