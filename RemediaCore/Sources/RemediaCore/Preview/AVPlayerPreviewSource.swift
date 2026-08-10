import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

public enum PreviewError: Error, Sendable {
    case imageGenerationFailed
    case pixelBufferCreationFailed
    case contextCreationFailed
}

/// Native preview for mov/mp4 sources. Uses `AVAssetImageGenerator` rather
/// than driving a live `AVPlayer`, since the preview only ever needs a still
/// frame at an arbitrary scrub time (REQUIREMENTS §5), not playback.
public actor AVPlayerPreviewSource: PreviewSource {
    public nonisolated let duration: TimeInterval
    // AVAssetImageGenerator is documented by Apple as safe for concurrent
    // use from multiple threads, so it's fine to hand to its own async
    // image(at:) call without the actor-isolation "sending" check.
    private nonisolated(unsafe) let imageGenerator: AVAssetImageGenerator

    public init(mediaFile: MediaFile) {
        self.duration = mediaFile.duration
        let asset = AVURLAsset(url: mediaFile.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.imageGenerator = generator
    }

    public func frame(at time: TimeInterval) async throws -> PreviewFrame {
        let requestedTime = CMTime(seconds: time, preferredTimescale: 600)
        let result = try await imageGenerator.image(at: requestedTime)
        return PreviewFrame(pixelBuffer: try Self.pixelBuffer(from: result.image))
    }

    private static func pixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        let width = cgImage.width
        let height = cgImage.height

        var unmanagedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &unmanagedBuffer
        )
        guard status == kCVReturnSuccess, let buffer = unmanagedBuffer else {
            throw PreviewError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw PreviewError.contextCreationFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
