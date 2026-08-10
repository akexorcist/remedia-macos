import Testing
import Foundation
import CoreGraphics
import CoreVideo
import CFFmpeg
@testable import RemediaCore

/// Regression coverage for the FFmpeg-native probe/preview SAR bug (webm
/// source's non-square pixels previously went uncorrected in
/// `cffmpeg_probe`/`cffmpeg_decode_frame_at`, unlike the AVFoundation path).
///
/// FFmpegEngine's transcode pipeline corrects SAR away before muxing, so an
/// anamorphic webm fixture can't be produced by converting an anamorphic
/// mov to webm — instead a square-pixel webm is bootstrapped normally, then
/// remuxed (stream copy) via `cffmpeg_force_sample_aspect_ratio` to force a
/// 4:3 SAR onto it, mirroring a real anamorphic encoder's output.
private enum AnamorphicWebmFixture {
    static func make(in directory: URL) async throws -> MediaFile {
        let movURL = directory.appendingPathComponent("bootstrap.mov")
        let encodedSize = CGSize(width: 320, height: 240)
        try await SyntheticMovie.makeQuadrantMovie(url: movURL, size: encodedSize, fps: 5, duration: 1.0)
        let movFile = try await MediaFileProber.probe(url: movURL)

        let squareWebmURL = directory.appendingPathComponent("square.webm")
        let bootstrapSettings = VideoSettings(trim: .full(duration: movFile.duration))
        let bootstrapJob = FFmpegEngine().convert(movFile, to: .webm, settings: .video(bootstrapSettings), outputURL: squareWebmURL)
        for await _ in await bootstrapJob.progress {}
        guard case .completed = await bootstrapJob.state else {
            Issue.record("square webm bootstrap failed: \(await bootstrapJob.state)")
            throw MediaProbeError.unreadableImageSource
        }

        let anamorphicWebmURL = directory.appendingPathComponent("anamorphic.webm")
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = squareWebmURL.path.withCString { inputC in
            anamorphicWebmURL.path.withCString { outputC in
                errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                    cffmpeg_force_sample_aspect_ratio(inputC, outputC, 4, 3, errorPtr.baseAddress, Int32(errorPtr.count))
                }
            }
        }
        guard status == 0 else {
            Issue.record("forcing SAR onto webm fixture failed: \(String(cString: errorBuffer))")
            throw MediaProbeError.unreadableImageSource
        }

        return try await MediaFileProber.probe(url: anamorphicWebmURL)
    }
}

@Test func webmSourceProbeReportsSARCorrectedDisplayResolution() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let probed = try await AnamorphicWebmFixture.make(in: tempDir)
    #expect(abs(probed.resolution.width - 426.667) < 1, "expected the SAR-corrected display width, not the raw 320")
    #expect(probed.resolution.height == 240)
}

@Test func webmSourcePreviewDecodesAtSARCorrectedDisplayResolution() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let probed = try await AnamorphicWebmFixture.make(in: tempDir)

    let previewSource = FFmpegDecodePreviewSource(mediaFile: probed)
    let frame = try await previewSource.frame(at: 0)
    let width = CVPixelBufferGetWidth(frame.pixelBuffer)
    let height = CVPixelBufferGetHeight(frame.pixelBuffer)

    #expect(
        abs(Double(width) - 426.667) < 1,
        "preview frame should decode at the display width, matching probe's resolution"
    )
    #expect(height == 240)
}

@Test func ffmpegEngineAnamorphicWebmSourceDoesNotShiftOrStretchCrop() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let probed = try await AnamorphicWebmFixture.make(in: tempDir)

    // Straddles the display-space quadrant boundary (213.333) asymmetrically;
    // misinterpreted against the raw 320-wide frame it would land at 30%
    // instead of the expected ~56.7%.
    let settings = VideoSettings(
        quality: 80,
        resolution: .original,
        frameRate: .original,
        trim: .full(duration: probed.duration),
        crop: CGRect(x: 100, y: 0, width: 200, height: 240),
        audio: .stripped
    )

    let outputURL = tempDir.appendingPathComponent("output.webm")
    let engine = FFmpegEngine()
    let job = engine.convert(probed, to: .webm, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete, got \(await job.state)")
        return
    }

    let frame = try await FramePixelInspector.firstFrame(of: outputURL, format: .webm)
    let boundary = FramePixelInspector.colorBoundaryFraction(
        in: frame, row: frame.height / 4,
        from: (255, 0, 0), to: (0, 255, 0)
    )
    let unwrappedBoundary = try #require(boundary, "expected a red-to-green transition somewhere in the output")
    let expectedFraction = (213.333 - 100) / 200
    #expect(
        abs(unwrappedBoundary - expectedFraction) < 0.08,
        "color boundary landed at \(unwrappedBoundary), expected ~\(expectedFraction) — anamorphic webm source's crop was shifted/stretched"
    )
}
