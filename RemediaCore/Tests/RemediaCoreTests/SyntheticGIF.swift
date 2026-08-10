import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum SyntheticGIFError: Error {
    case destinationCreationFailed
    case imageCreationFailed
    case finalizationFailed
}

/// Generates a short solid-color animated GIF via ImageIO — deliberately
/// independent of FFmpegEngine's own gif encoder, so tests using this as a
/// source fixture aren't validating our own encoder against itself (see
/// docs/CONVERSION_MATRIX_TEST_PLAN.md).
enum SyntheticGIF {
    static func makeSolidColorGIF(url: URL, size: CGSize, frameCount: Int, frameDelay: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else {
            throw SyntheticGIFError.destinationCreationFailed
        }

        let containerProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)

        for frameIndex in 0..<frameCount {
            guard let image = makeCGImage(size: size, frameIndex: frameIndex) else {
                throw SyntheticGIFError.imageCreationFailed
            }
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                    kCGImagePropertyGIFDelayTime: frameDelay
                ]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticGIFError.finalizationFailed
        }
    }

    /// Single frame split into four solid-color quadrants (top-left,
    /// top-right, bottom-left, bottom-right) — same red/green/blue/yellow
    /// scheme as `SyntheticMovie.makeQuadrantMovie`, so a crop's pixel
    /// content can be verified the same way regardless of source format.
    static func makeQuadrantGIF(url: URL, size: CGSize, frameCount: Int, frameDelay: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else {
            throw SyntheticGIFError.destinationCreationFailed
        }

        let containerProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)

        for _ in 0..<frameCount {
            guard let image = makeQuadrantCGImage(size: size) else {
                throw SyntheticGIFError.imageCreationFailed
            }
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                    kCGImagePropertyGIFDelayTime: frameDelay
                ]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw SyntheticGIFError.finalizationFailed
        }
    }

    private static func makeQuadrantCGImage(size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }

        let halfWidth = CGFloat(width) / 2
        let halfHeight = CGFloat(height) / 2
        // CGContext's own coordinate space is Y-up (origin bottom-left), so
        // "top" quadrants are drawn at the *upper* y range here.
        let quadrants: [(rect: CGRect, color: (CGFloat, CGFloat, CGFloat))] = [
            (CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), (1, 0, 0)),           // top-left: red
            (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), (0, 1, 0)),   // top-right: green
            (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), (0, 0, 1)),                    // bottom-left: blue
            (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), (1, 1, 0))             // bottom-right: yellow
        ]
        for (rect, color) in quadrants {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1.0)
            context.fill(rect)
        }

        return context.makeImage()
    }

    private static func makeCGImage(size: CGSize, frameIndex: Int) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }

        // Cycle the color per frame, matching SyntheticMovie's pattern.
        let channelValue = CGFloat((frameIndex * 37) % 256) / 255.0
        context.setFillColor(red: channelValue, green: 100.0 / 255.0, blue: 150.0 / 255.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()
    }
}
