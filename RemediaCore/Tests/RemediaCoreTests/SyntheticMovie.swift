import Foundation
import AVFoundation
import CoreVideo

enum SyntheticMovieError: Error {
    case pixelBufferCreationFailed
}

/// Generates short synthetic .mov files so `AVFoundationEngine` can be
/// exercised end-to-end without needing user-supplied sample media, which
/// isn't available in this environment.
enum SyntheticMovie {
    static func makeSolidColorMovie(
        url: URL,
        size: CGSize,
        fps: Int32,
        duration: Double,
        fileType: AVFileType = .mov
    ) async throws {
        try await write(url: url, size: size, fps: fps, duration: duration, transform: .identity, pixelAspectRatio: nil, fileType: fileType) { buffer, frameIndex in
            // Cycle the color per frame — not required by the tests, but
            // makes the output scrubbable/inspectable by eye if ever needed.
            let channelValue = UInt8((frameIndex * 37) % 256)
            fillPixels(of: buffer) { _, _ in (255, channelValue, 100, 150) }
        }
    }

    /// Single frame split into four solid-color quadrants, so a test can
    /// verify a crop+scale pipeline didn't stretch content unevenly — a
    /// dimensions-only check can't catch that. `transform` sets the track's
    /// `preferredTransform` (e.g. a 90° rotation); `size` is always the raw
    /// pre-rotation pixel-buffer size.
    static func makeQuadrantMovie(
        url: URL,
        size: CGSize,
        fps: Int32,
        duration: Double,
        transform: CGAffineTransform = .identity,
        fileType: AVFileType = .mov
    ) async throws {
        try await write(url: url, size: size, fps: fps, duration: duration, transform: transform, pixelAspectRatio: nil, fileType: fileType) { buffer, _ in
            fillPixels(of: buffer) { row, col in
                let isTop = row < Int(size.height) / 2
                let isLeft = col < Int(size.width) / 2
                switch (isTop, isLeft) {
                case (true, true): return (255, 255, 0, 0)     // top-left: red
                case (true, false): return (255, 0, 255, 0)    // top-right: green
                case (false, true): return (255, 0, 0, 255)    // bottom-left: blue
                case (false, false): return (255, 255, 255, 0) // bottom-right: yellow
                }
            }
        }
    }

    /// Same as `makeQuadrantMovie`, but the H.264 stream also carries
    /// non-square pixel-aspect-ratio (SAR/PAR) metadata — `encodedSize` is
    /// the raw stored pixel grid; `pixelAspectRatio` (horizontal:vertical
    /// spacing) stretches that to a different *displayed* size. Reproduces
    /// an anamorphic source, e.g. a 320x240 (4:3) stream tagged to display
    /// at 426.667x240 (16:9).
    static func makeAnamorphicQuadrantMovie(
        url: URL,
        encodedSize: CGSize,
        pixelAspectRatio: (horizontal: Int, vertical: Int),
        fps: Int32,
        duration: Double,
        fileType: AVFileType = .mov
    ) async throws {
        try await write(
            url: url, size: encodedSize, fps: fps, duration: duration,
            transform: .identity, pixelAspectRatio: pixelAspectRatio, fileType: fileType
        ) { buffer, _ in
            fillPixels(of: buffer) { row, col in
                let isTop = row < Int(encodedSize.height) / 2
                let isLeft = col < Int(encodedSize.width) / 2
                switch (isTop, isLeft) {
                case (true, true): return (255, 255, 0, 0)     // top-left: red
                case (true, false): return (255, 0, 255, 0)    // top-right: green
                case (false, true): return (255, 0, 0, 255)    // bottom-left: blue
                case (false, false): return (255, 255, 255, 0) // bottom-right: yellow
                }
            }
        }
    }

    private static func write(
        url: URL,
        size: CGSize,
        fps: Int32,
        duration: Double,
        transform: CGAffineTransform,
        pixelAspectRatio: (horizontal: Int, vertical: Int)?,
        fileType: AVFileType,
        pixelFill: @escaping (CVPixelBuffer, Int) -> Void
    ) async throws {
        let writer = try AVAssetWriter(url: url, fileType: fileType)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        if let pixelAspectRatio {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoPixelAspectRatioKey: [
                    AVVideoPixelAspectRatioHorizontalSpacingKey: pixelAspectRatio.horizontal,
                    AVVideoPixelAspectRatioVerticalSpacingKey: pixelAspectRatio.vertical
                ]
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else { throw SyntheticMovieError.pixelBufferCreationFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SyntheticMovieError.pixelBufferCreationFailed }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(duration * Double(fps))
        let queue = DispatchQueue(label: "SyntheticMovie.writer")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var frameIndex = 0
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if frameIndex >= frameCount {
                        input.markAsFinished()
                        writer.finishWriting {
                            if let error = writer.error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                        return
                    }
                    guard let pixelBuffer = makePixelBuffer(size: size) else {
                        input.markAsFinished()
                        continuation.resume(throwing: SyntheticMovieError.pixelBufferCreationFailed)
                        return
                    }
                    pixelFill(pixelBuffer, frameIndex)
                    let time = CMTime(value: Int64(frameIndex), timescale: CMTimeScale(fps))
                    adaptor.append(pixelBuffer, withPresentationTime: time)
                    frameIndex += 1
                }
            }
        }
    }

    private static func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        var unmanagedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &unmanagedBuffer
        )
        guard status == kCVReturnSuccess, let buffer = unmanagedBuffer else { return nil }
        return buffer
    }

    /// `provider(row, col)` returns `(a, r, g, b)` for that pixel.
    private static func fillPixels(of buffer: CVPixelBuffer, provider: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBase = base.assumingMemoryBound(to: UInt8.self)

        for row in 0..<height {
            let rowStart = rowBase + row * bytesPerRow
            for col in 0..<width {
                let pixel = rowStart + col * 4
                let (a, r, g, b) = provider(row, col)
                pixel[0] = a
                pixel[1] = r
                pixel[2] = g
                pixel[3] = b
            }
        }
    }
}
