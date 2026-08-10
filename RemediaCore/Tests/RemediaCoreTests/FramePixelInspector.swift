import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
@testable import RemediaCore

/// Decodes a single frame into raw RGBA pixels so a test can verify actual
/// content proportions, not just reported width/height (which an encoder
/// satisfies regardless of whether the content was stretched to fit). Uses
/// the same decode path the app itself uses per format (ARCHITECTURE §3).
enum FramePixelInspectorError: Error {
    case contextCreationFailed
    case noFramesInSource
}

enum FramePixelInspector {
    struct DecodedFrame {
        let width: Int
        let height: Int
        private let rgba: [UInt8]

        fileprivate init(rgba: [UInt8], width: Int, height: Int) {
            self.rgba = rgba
            self.width = width
            self.height = height
        }

        /// `y` is measured from the top of the frame, matching
        /// `SyntheticMovie`'s own pixel-writing convention.
        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let offset = (y * width + x) * 4
            return (rgba[offset], rgba[offset + 1], rgba[offset + 2])
        }
    }

    static func firstFrame(of url: URL, format: OutputFormat) async throws -> DecodedFrame {
        switch format {
        case .mov, .mp4:
            return try await firstFrameViaAVFoundation(url: url)
        case .gif:
            return try firstFrameViaImageIO(url: url)
        case .webm:
            return try await firstFrameViaFFmpeg(url: url)
        }
    }

    private static func firstFrameViaAVFoundation(url: URL) async throws -> DecodedFrame {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // Defaults to false — without it, a rotated (preferredTransform)
        // source decodes in its raw, pre-rotation pixel layout instead of
        // the displayed orientation.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cgImage = try await generator.image(at: .zero).image
        return try decodedFrame(from: cgImage)
    }

    private static func firstFrameViaImageIO(url: URL) throws -> DecodedFrame {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FramePixelInspectorError.noFramesInSource
        }
        return try decodedFrame(from: cgImage)
    }

    private static func firstFrameViaFFmpeg(url: URL) async throws -> DecodedFrame {
        let mediaFile = try await MediaFileProber.probe(url: url)
        let previewSource = FFmpegDecodePreviewSource(mediaFile: mediaFile)
        let frame = try await previewSource.frame(at: 0)
        return decodedFrame(fromBGRAPixelBuffer: frame.pixelBuffer)
    }

    private static func decodedFrame(from cgImage: CGImage) throws -> DecodedFrame {
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FramePixelInspectorError.contextCreationFailed
        }
        // No flip needed: a fresh CGContext's default CTM already lands the
        // image's row 0 at buffer row 0 (confirmed empirically — adding one
        // doubled up and inverted it).
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return DecodedFrame(rgba: buffer, width: width, height: height)
    }

    /// `FFmpegDecodePreviewSource`'s pixel buffers are BGRA
    /// (`BGRAPixelBufferBuilder`) — byte-swapped into the same RGBA layout
    /// `decodedFrame(from:)` produces so `pixel(x:y:)` behaves identically
    /// regardless of which decode path produced the frame.
    private static func decodedFrame(fromBGRAPixelBuffer buffer: CVPixelBuffer) -> DecodedFrame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return DecodedFrame(rgba: rgba, width: width, height: height)
        }

        for row in 0..<height {
            let srcRowStart = base + row * bytesPerRow
            let dstRowStart = row * width * 4
            for col in 0..<width {
                let src = srcRowStart + col * 4
                let dst = dstRowStart + col * 4
                rgba[dst] = src[2]     // R
                rgba[dst + 1] = src[1] // G
                rgba[dst + 2] = src[0] // B
                rgba[dst + 3] = src[3] // A
            }
        }
        return DecodedFrame(rgba: rgba, width: width, height: height)
    }

    /// Fraction (0...1) down `column` where the pixel color switches from
    /// closer-to-`from` to closer-to-`to`. Nearest-color rather than exact
    /// match, since compression can soften a sharp edge.
    static func colorBoundaryFraction(
        in frame: DecodedFrame, column: Int,
        from: (r: UInt8, g: UInt8, b: UInt8), to: (r: UInt8, g: UInt8, b: UInt8)
    ) -> Double? {
        func distanceSquared(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
            let dr = Int(a.r) - Int(b.r)
            let dg = Int(a.g) - Int(b.g)
            let db = Int(a.b) - Int(b.b)
            return dr * dr + dg * dg + db * db
        }
        for row in 0..<frame.height {
            let pixel = frame.pixel(x: column, y: row)
            if distanceSquared(pixel, to) < distanceSquared(pixel, from) {
                return Double(row) / Double(frame.height)
            }
        }
        return nil
    }

    /// Same as `colorBoundaryFraction(in:column:from:to:)`, but scans
    /// across `row` (left to right) instead — for a left/right split rather
    /// than a top/bottom one.
    static func colorBoundaryFraction(
        in frame: DecodedFrame, row: Int,
        from: (r: UInt8, g: UInt8, b: UInt8), to: (r: UInt8, g: UInt8, b: UInt8)
    ) -> Double? {
        func distanceSquared(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
            let dr = Int(a.r) - Int(b.r)
            let dg = Int(a.g) - Int(b.g)
            let db = Int(a.b) - Int(b.b)
            return dr * dr + dg * dg + db * db
        }
        for col in 0..<frame.width {
            let pixel = frame.pixel(x: col, y: row)
            if distanceSquared(pixel, to) < distanceSquared(pixel, from) {
                return Double(col) / Double(frame.width)
            }
        }
        return nil
    }
}
