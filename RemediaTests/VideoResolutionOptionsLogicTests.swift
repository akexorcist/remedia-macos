import XCTest
@testable import Remedia
@testable import RemediaCore

final class VideoResolutionOptionsLogicTests: XCTestCase {
    // MARK: - resolutionOptions

    /// No collisions between the fixed widths and the scale-factor widths
    /// (810/540/270) for this source, so all nine qualifying fixed widths
    /// (< 1080) survive alongside the three scale factors.
    func testResolutionOptionsForWideSourceWithNoCollisions() {
        let options = VideoSettingsView.resolutionOptions(sourceWidth: 1080)
        XCTAssertEqual(options, [
            .original,
            .customWidth(960),
            .scale(0.75),
            .customWidth(800),
            .customWidth(720),
            .customWidth(640),
            .customWidth(600),
            .scale(0.5),
            .customWidth(480),
            .customWidth(400),
            .customWidth(320),
            .customWidth(280),
            .scale(0.25)
        ])
    }

    /// 0.75x of 800 is 600, and 0.5x is 400 — both exact matches to
    /// predefined fixed widths, so those two fixed-width entries are
    /// dropped in favor of the scale-factor ones.
    func testResolutionOptionsDropsFixedWidthsThatCollideWithScaleFactors() {
        let options = VideoSettingsView.resolutionOptions(sourceWidth: 800)
        XCTAssertEqual(options, [
            .original,
            .customWidth(720),
            .customWidth(640),
            .scale(0.75),
            .customWidth(480),
            .scale(0.5),
            .customWidth(320),
            .customWidth(280),
            .scale(0.25)
        ])
        XCTAssertFalse(options.contains(.customWidth(600)))
        XCTAssertFalse(options.contains(.customWidth(400)))
    }

    /// 1600 and 1200 aren't narrower than the 1080 source, so they never
    /// appear regardless of collisions.
    func testResolutionOptionsExcludesFixedWidthsAtOrAboveSource() {
        let options = VideoSettingsView.resolutionOptions(sourceWidth: 1080)
        XCTAssertFalse(options.contains(.customWidth(1600)))
        XCTAssertFalse(options.contains(.customWidth(1200)))
    }

    /// No fixed width is narrower than a 240px-wide source — falls back to
    /// just Original plus the three scale factors.
    func testResolutionOptionsForNarrowSourceHasNoFixedWidths() {
        let options = VideoSettingsView.resolutionOptions(sourceWidth: 240)
        XCTAssertEqual(options, [.original, .scale(0.75), .scale(0.5), .scale(0.25)])
    }

    func testResolutionOptionsForZeroSourceWidthIsJustOriginal() {
        XCTAssertEqual(VideoSettingsView.resolutionOptions(sourceWidth: 0), [.original])
    }

    /// `.original` is always first regardless of source width, and every
    /// following entry's resulting width is strictly decreasing.
    func testResolutionOptionsOrderingInvariant() {
        for sourceWidth: CGFloat in [3840, 1920, 1280, 960, 500] {
            let options = VideoSettingsView.resolutionOptions(sourceWidth: sourceWidth)
            XCTAssertEqual(options.first, .original, "source \(sourceWidth)")

            let widths = options.dropFirst().map { resolution -> Int in
                switch resolution {
                case .original: return Int(sourceWidth)
                case .scale(let factor): return Int(sourceWidth * factor)
                case .customWidth(let width): return width
                }
            }
            XCTAssertEqual(widths, widths.sorted(by: >), "source \(sourceWidth) options should be strictly descending by width")
        }
    }
}
