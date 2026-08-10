import Testing
import Foundation
import CoreVideo
import CoreGraphics
@testable import RemediaCore

/// Bootstraps via FFmpegEngine's own encoder — fine here since this test is
/// about the *decode* path, a different code path than encoding (see
/// docs/CONVERSION_MATRIX_TEST_PLAN.md for the non-circularity rationale).
private func makeWebmFixture(in directory: URL, size: CGSize, fps: Int32, duration: Double) async throws -> MediaFile {
    let movURL = directory.appendingPathComponent("bootstrap.mov")
    try await SyntheticMovie.makeSolidColorMovie(url: movURL, size: size, fps: fps, duration: duration)
    let movFile = try await MediaFileProber.probe(url: movURL)

    let webmURL = directory.appendingPathComponent("fixture.webm")
    let settings = VideoSettings(trim: .full(duration: movFile.duration))
    let job = FFmpegEngine().convert(movFile, to: .webm, settings: .video(settings), outputURL: webmURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("webm fixture bootstrap failed: \(await job.state)")
        throw MediaProbeError.unreadableImageSource
    }
    return try await MediaFileProber.probe(url: webmURL)
}

/// Exact source bytes won't survive H.264 compression, but a real decoded
/// frame should never come back literally all-zero (what `sws_scale`
/// produces from a NULL frame — see preview_decode.c's lastGoodFrame
/// handling), and our synthetic frames are opaque, so alpha reads near 255.
private func assertLooksLikeRealFrame(_ pixelBuffer: CVPixelBuffer, sourceLabel: String) {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        Issue.record("\(sourceLabel): could not access pixel buffer memory")
        return
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)

    var nonZeroCount = 0
    var alphaSum = 0
    let sampleRows = stride(from: 0, to: height, by: max(1, height / 8))
    var sampledPixels = 0
    for row in sampleRows {
        for col in stride(from: 0, to: bytesPerRow - 4, by: 4) {
            let pixel = bytes + row * bytesPerRow + col
            if pixel[0] != 0 || pixel[1] != 0 || pixel[2] != 0 { nonZeroCount += 1 }
            alphaSum += Int(pixel[3]) // BGRA: alpha is byte index 3
            sampledPixels += 1
        }
    }

    #expect(nonZeroCount > 0, "\(sourceLabel): decoded frame was entirely black/zero — likely fed sws_scale a cleared frame")
    let averageAlpha = sampledPixels > 0 ? alphaSum / sampledPixels : 0
    #expect(averageAlpha > 200, "\(sourceLabel): average alpha \(averageAlpha) looks wrong for a fully-opaque synthetic source")
}

@Test func ffmpegDecodePreviewSourceReturnsCorrectlySizedFrames() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceSize = CGSize(width: 320, height: 240)
    let webmFile = try await makeWebmFixture(in: tempDir, size: sourceSize, fps: 10, duration: 2.0)

    let previewSource = FFmpegDecodePreviewSource(mediaFile: webmFile)
    #expect(previewSource.duration > 0)

    for time in [0.0, 0.5, 1.0, 1.5] {
        let frame = try await previewSource.frame(at: time)
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        #expect(width == Int(sourceSize.width), "frame at \(time)s had unexpected width \(width)")
        #expect(height == Int(sourceSize.height), "frame at \(time)s had unexpected height \(height)")
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA)
        assertLooksLikeRealFrame(frame.pixelBuffer, sourceLabel: "t=\(time)")
    }
}

@Test func ffmpegDecodePreviewSourceHandlesTimeNearEnd() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceSize = CGSize(width: 320, height: 240)
    let webmFile = try await makeWebmFixture(in: tempDir, size: sourceSize, fps: 10, duration: 1.0)

    let previewSource = FFmpegDecodePreviewSource(mediaFile: webmFile)
    // Requesting a time past the last frame should still return the last
    // decodable frame rather than throwing.
    let frame = try await previewSource.frame(at: webmFile.duration + 5.0)
    #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == Int(sourceSize.width))
    assertLooksLikeRealFrame(frame.pixelBuffer, sourceLabel: "past-end fallback")
}

@Test func ffmpegDecodePreviewSourceOnGifFixture() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let movURL = tempDir.appendingPathComponent("bootstrap.mov")
    let sourceSize = CGSize(width: 160, height: 120)
    try await SyntheticMovie.makeSolidColorMovie(url: movURL, size: sourceSize, fps: 10, duration: 1.0)
    let movFile = try await MediaFileProber.probe(url: movURL)

    let gifURL = tempDir.appendingPathComponent("fixture.gif")
    let gifSettings = GifSettings(trim: .full(duration: movFile.duration))
    let job = FFmpegEngine().convert(movFile, to: .gif, settings: .gif(gifSettings), outputURL: gifURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("gif fixture bootstrap failed: \(await job.state)")
        return
    }
    let gifFile = try await MediaFileProber.probe(url: gifURL)

    let previewSource = FFmpegDecodePreviewSource(mediaFile: gifFile)
    let frame = try await previewSource.frame(at: 0.0)
    #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == Int(sourceSize.width))
    #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == Int(sourceSize.height))
}
