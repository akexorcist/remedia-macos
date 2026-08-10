import XCTest
@testable import Remedia

final class CropOverlayGeometryTests: XCTestCase {
    // MARK: - letterboxedContentRect

    func testLetterboxedContentRectPillarboxesNarrowerSource() {
        // 4:3 source in a 16:9 container needs bars on the sides.
        let contentRect = CropOverlayView.letterboxedContentRect(
            containerSize: CGSize(width: 1600, height: 900), sourceSize: CGSize(width: 4, height: 3)
        )
        XCTAssertEqual(contentRect.height, 900, accuracy: 0.001)
        XCTAssertLessThan(contentRect.width, 1600)
        XCTAssertEqual(contentRect.midX, 800, accuracy: 0.001, "should be horizontally centered")
        XCTAssertEqual(contentRect.minY, 0, accuracy: 0.001)
    }

    func testLetterboxedContentRectLetterboxesWiderSource() {
        // 21:9 source in a 16:9 container needs bars on top/bottom.
        let contentRect = CropOverlayView.letterboxedContentRect(
            containerSize: CGSize(width: 1600, height: 900), sourceSize: CGSize(width: 21, height: 9)
        )
        XCTAssertEqual(contentRect.width, 1600, accuracy: 0.001)
        XCTAssertLessThan(contentRect.height, 900)
        XCTAssertEqual(contentRect.midY, 450, accuracy: 0.001, "should be vertically centered")
        XCTAssertEqual(contentRect.minX, 0, accuracy: 0.001)
    }

    func testLetterboxedContentRectMatchingAspectFillsExactly() {
        let contentRect = CropOverlayView.letterboxedContentRect(
            containerSize: CGSize(width: 1600, height: 900), sourceSize: CGSize(width: 16, height: 9)
        )
        XCTAssertEqual(contentRect, CGRect(x: 0, y: 0, width: 1600, height: 900))
    }

    func testLetterboxedContentRectDegenerateSizesFallBackToFullContainer() {
        let container = CGSize(width: 1600, height: 900)
        XCTAssertEqual(CropOverlayView.letterboxedContentRect(containerSize: container, sourceSize: .zero), CGRect(origin: .zero, size: container))
    }

    // MARK: - viewRect / sourceRect round trip

    func testViewAndSourceRectRoundTrip() {
        let sourceSize = CGSize(width: 320, height: 240)
        let contentRect = CGRect(x: 20, y: 0, width: 600, height: 450)
        let original = CGRect(x: 40, y: 30, width: 120, height: 90)

        let view = CropOverlayView.viewRect(forSourceRect: original, sourceSize: sourceSize, contentRect: contentRect)
        let roundTripped = CropOverlayView.sourceRect(forViewRect: view, sourceSize: sourceSize, contentRect: contentRect)

        XCTAssertEqual(roundTripped.origin.x, original.origin.x, accuracy: 0.01)
        XCTAssertEqual(roundTripped.origin.y, original.origin.y, accuracy: 0.01)
        XCTAssertEqual(roundTripped.width, original.width, accuracy: 0.01)
        XCTAssertEqual(roundTripped.height, original.height, accuracy: 0.01)
    }

    func testViewRectAppliesUniformScaleOnBothAxes() {
        // contentRect is exactly 2x sourceSize on both axes — a non-uniform
        // scale bug would show up as width/height scaling by different
        // factors here.
        let sourceSize = CGSize(width: 100, height: 50)
        let contentRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let view = CropOverlayView.viewRect(
            forSourceRect: CGRect(x: 10, y: 10, width: 30, height: 20), sourceSize: sourceSize, contentRect: contentRect
        )
        XCTAssertEqual(view, CGRect(x: 20, y: 20, width: 60, height: 40))
    }

    // MARK: - clamped

    func testClampedLeavesInBoundsRectUnchanged() {
        let sourceSize = CGSize(width: 320, height: 240)
        let rect = CGRect(x: 10, y: 10, width: 100, height: 80)
        XCTAssertEqual(CropOverlayView.clamped(rect, within: sourceSize), rect)
    }

    func testClampedPullsBackAnOriginThatOverflowsPastTheFarEdge() {
        let sourceSize = CGSize(width: 320, height: 240)
        let rect = CGRect(x: 300, y: 220, width: 100, height: 80)
        let result = CropOverlayView.clamped(rect, within: sourceSize)
        XCTAssertEqual(result.maxX, sourceSize.width, accuracy: 0.001)
        XCTAssertEqual(result.maxY, sourceSize.height, accuracy: 0.001)
        XCTAssertEqual(result.width, 100, accuracy: 0.001, "clamping should reposition, not shrink, a rect that already fits")
        XCTAssertEqual(result.height, 80, accuracy: 0.001)
    }

    func testClampedShrinksARectLargerThanTheSource() {
        let sourceSize = CGSize(width: 320, height: 240)
        let rect = CGRect(x: -20, y: -20, width: 400, height: 300)
        let result = CropOverlayView.clamped(rect, within: sourceSize)
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 320, height: 240))
    }

    // MARK: - constrainedSize

    func testConstrainedSizeWithNoAspectPassesRawValuesThrough() {
        let size = CropOverlayView.constrainedSize(rawWidth: 40, rawHeight: 70, aspect: nil)
        XCTAssertEqual(size, CGSize(width: 40, height: 70))
    }

    func testConstrainedSizeIsWidthDrivenWhenWidthIsTheLimit() {
        // rawWidth/aspect (100/2 = 50) <= rawHeight (80), so width should
        // drive the result.
        let size = CropOverlayView.constrainedSize(rawWidth: 100, rawHeight: 80, aspect: 2.0)
        XCTAssertEqual(size.width, 100, accuracy: 0.001)
        XCTAssertEqual(size.height, 50, accuracy: 0.001)
    }

    func testConstrainedSizeIsHeightDrivenWhenHeightIsTheLimit() {
        // rawWidth/aspect (100/2 = 50) > rawHeight (30), so height should
        // drive the result.
        let size = CropOverlayView.constrainedSize(rawWidth: 100, rawHeight: 30, aspect: 2.0)
        XCTAssertEqual(size.width, 60, accuracy: 0.001)
        XCTAssertEqual(size.height, 30, accuracy: 0.001)
    }

    func testConstrainedSizeNeverExceedsEitherRawBound() {
        for aspect in [0.3, 0.5, 1.0, 1.5, 2.0, 3.0] {
            let size = CropOverlayView.constrainedSize(rawWidth: 90, rawHeight: 40, aspect: aspect)
            XCTAssertLessThanOrEqual(size.width, 90.0001, "aspect \(aspect)")
            XCTAssertLessThanOrEqual(size.height, 40.0001, "aspect \(aspect)")
        }
    }

    // MARK: - aspectLockedRect

    func testAspectLockedRectAnchorsAtFixedPointDraggingDownRight() {
        let fixed = CGPoint(x: 0, y: 0)
        let dragged = CGPoint(x: 100, y: 100)
        let rect = CropOverlayView.aspectLockedRect(fixedPoint: fixed, draggedPoint: dragged, aspect: 2.0)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width / rect.height, 2.0, accuracy: 0.001)
    }

    func testAspectLockedRectAnchorsAtFixedPointDraggingUpLeft() {
        let fixed = CGPoint(x: 200, y: 200)
        let dragged = CGPoint(x: 100, y: 150)
        let rect = CropOverlayView.aspectLockedRect(fixedPoint: fixed, draggedPoint: dragged, aspect: 2.0)
        XCTAssertEqual(rect.maxX, 200, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 200, accuracy: 0.001)
        XCTAssertEqual(rect.width / rect.height, 2.0, accuracy: 0.001)
    }

    func testAspectLockedRectHandlesMixedQuadrant() {
        // Dragging up-and-right from the fixed point.
        let fixed = CGPoint(x: 100, y: 100)
        let dragged = CGPoint(x: 200, y: 50)
        let rect = CropOverlayView.aspectLockedRect(fixedPoint: fixed, draggedPoint: dragged, aspect: 1.0)
        XCTAssertEqual(rect.minX, 100, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 100, accuracy: 0.001)
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001)
    }

    // MARK: - centerPivotRect

    func testCenterPivotRectIsSymmetricAroundCenter() {
        let center = CGPoint(x: 100, y: 100)
        let dragged = CGPoint(x: 150, y: 130)
        let rect = CropOverlayView.centerPivotRect(center: center, draggedPoint: dragged, aspect: nil)
        XCTAssertEqual(rect.midX, center.x, accuracy: 0.001)
        XCTAssertEqual(rect.midY, center.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 60, accuracy: 0.001)
    }

    func testCenterPivotRectRespectsAspectLock() {
        let center = CGPoint(x: 100, y: 100)
        let dragged = CGPoint(x: 180, y: 110)
        let rect = CropOverlayView.centerPivotRect(center: center, draggedPoint: dragged, aspect: 1.0)
        XCTAssertEqual(rect.midX, center.x, accuracy: 0.001)
        XCTAssertEqual(rect.midY, center.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001)
    }

    // MARK: - point(for:in:) / Corner.opposite

    func testPointForEachCorner() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(CropOverlayView.point(for: .topLeft, in: rect), CGPoint(x: 10, y: 20))
        XCTAssertEqual(CropOverlayView.point(for: .topRight, in: rect), CGPoint(x: 110, y: 20))
        XCTAssertEqual(CropOverlayView.point(for: .bottomLeft, in: rect), CGPoint(x: 10, y: 70))
        XCTAssertEqual(CropOverlayView.point(for: .bottomRight, in: rect), CGPoint(x: 110, y: 70))
    }

    func testCornerOppositePairings() {
        XCTAssertEqual(CropOverlayView.Corner.topLeft.opposite, .bottomRight)
        XCTAssertEqual(CropOverlayView.Corner.topRight.opposite, .bottomLeft)
        XCTAssertEqual(CropOverlayView.Corner.bottomLeft.opposite, .topRight)
        XCTAssertEqual(CropOverlayView.Corner.bottomRight.opposite, .topLeft)
    }
}
