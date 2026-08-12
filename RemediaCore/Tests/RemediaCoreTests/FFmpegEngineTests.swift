import Testing
import Foundation
import CoreGraphics
import CoreMedia
@testable import RemediaCore

/// The webm target's fixed libvpx-vp9 codec is unaffected by this setting
/// (per `FFmpegEngine.videoCodecName`, only mp4/mov consult it) — this
/// exercises the mp4/mov branch, which real usage reaches whenever the
/// *source* (not just the target) isn't natively readable, e.g. gif/webm to
/// mp4/mov, routing through FFmpegEngine despite the native-looking target.
@Test func ffmpegEngineRespectsExplicitVideoCodecChoice() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: CGSize(width: 320, height: 240), fps: 10, duration: 1.0)
    let probed = try await MediaFileProber.probe(url: sourceURL)
    let engine = FFmpegEngine()

    for codec: VideoCodec in [.h264, .hevc] {
        let settings = VideoSettings(trim: TrimRange(start: 0, end: 1.0), audio: .stripped, videoCodec: codec)
        let outputURL = tempDir.appendingPathComponent("output-\(codec.rawValue).mp4")
        let job = engine.convert(probed, to: .mp4, settings: .video(settings), outputURL: outputURL)
        for await _ in await job.progress {}
        guard case .completed = await job.state else {
            Issue.record("expected \(codec) job to complete")
            continue
        }
        let actualFourCC = try await VideoCodecInspector.videoCodec(of: outputURL)
        let acceptable = VideoCodecInspector.acceptableFourCCs(for: codec)
        #expect(acceptable.contains(actualFourCC), "\(codec) produced codec fourCC \(actualFourCC), expected one of \(acceptable)")
    }
}

@Test func ffmpegEngineConvertsMovToWebmWithTrimCropAndScale() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let sourceSize = CGSize(width: 640, height: 480)
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: sourceSize, fps: 10, duration: 4.0)

    let probed = try await MediaFileProber.probe(url: sourceURL)

    let settings = VideoSettings(
        quality: 60,
        resolution: .scale(0.5),
        frameRate: .original,
        trim: TrimRange(start: 1.0, end: 3.0),
        crop: CGRect(x: 100, y: 50, width: 300, height: 200),
        audio: .stripped
    )

    let outputURL = tempDir.appendingPathComponent("output.webm")
    let engine = FFmpegEngine()
    let job = engine.convert(probed, to: .webm, settings: .video(settings), outputURL: outputURL)

    for await _ in await job.progress {}

    guard case .completed(let resultURL) = await job.state else {
        Issue.record("expected job to complete")
        return
    }
    #expect(resultURL == outputURL)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(abs(outputProbe.duration - 2.0) < 0.5)
    #expect(outputProbe.resolution.width == 150)
    #expect(outputProbe.resolution.height == 100)
    #expect(outputProbe.hasAudio == false)
}

/// FFmpeg-engine half of the anamorphic-source bug (see
/// `avFoundationEngineAnamorphicSourceDoesNotShiftOrStretchCrop` for the
/// AVFoundation half): an SAR source converted to webm/gif also routes
/// through `FFmpegEngine`, whose decoder produces frames at the raw storage
/// size — the same mismatch, recreated in the C transcode pipeline.
@Test func ffmpegEngineAnamorphicMovSourceToWebmDoesNotShiftOrStretchCrop() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let encodedSize = CGSize(width: 320, height: 240)
    try await SyntheticMovie.makeAnamorphicQuadrantMovie(
        url: sourceURL, encodedSize: encodedSize, pixelAspectRatio: (horizontal: 4, vertical: 3),
        fps: 5, duration: 1.0
    )

    let probed = try await MediaFileProber.probe(url: sourceURL)
    #expect(abs(probed.resolution.width - 426.667) < 1, "expected the SAR-corrected display width, not the raw 320")
    #expect(probed.resolution.height == 240)

    // Same straddling crop as the AVFoundation-engine version: expected
    // fraction ≈56.7%; misread against the raw 320-wide frame it's 30%.
    let settings = VideoSettings(
        quality: 80,
        resolution: .original,
        frameRate: .original,
        trim: .full(duration: 1.0),
        crop: CGRect(x: 100, y: 0, width: 200, height: 240),
        audio: .stripped
    )

    let outputURL = tempDir.appendingPathComponent("output.webm")
    let engine = FFmpegEngine()
    let job = engine.convert(probed, to: .webm, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete")
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
        "color boundary landed at \(unwrappedBoundary), expected ~\(expectedFraction) — anamorphic source's crop was shifted/stretched"
    )
}

/// Same class of regression as `avFoundationEngineEdgeTouchingCropDoesNotStretchContent`,
/// verified via pixel content decoded with the FFmpeg bridge (AVFoundation
/// can't read webm — ARCHITECTURE §5).
@Test func ffmpegEngineEdgeTouchingCropDoesNotStretchContent() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let sourceSize = CGSize(width: 400, height: 300)
    try await SyntheticMovie.makeQuadrantMovie(url: sourceURL, size: sourceSize, fps: 5, duration: 1.0)

    let probed = try await MediaFileProber.probe(url: sourceURL)
    #expect(probed.resolution == sourceSize)

    // Right half of the source, touching top/bottom/right edges: keeps only
    // the green (top-right) and yellow (bottom-right) quadrants, split at
    // the vertical midpoint.
    let settings = VideoSettings(
        quality: 80,
        resolution: .original,
        frameRate: .original,
        trim: .full(duration: 1.0),
        crop: CGRect(x: 200, y: 0, width: 200, height: 300),
        audio: .stripped
    )

    let outputURL = tempDir.appendingPathComponent("output.webm")
    let engine = FFmpegEngine()
    let job = engine.convert(probed, to: .webm, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete")
        return
    }

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(outputProbe.resolution.width == 200)
    #expect(outputProbe.resolution.height == 300)

    let frame = try await FramePixelInspector.firstFrame(of: outputURL, format: .webm)
    let boundary = FramePixelInspector.colorBoundaryFraction(
        in: frame, column: frame.width / 2,
        from: (0, 255, 0), to: (255, 255, 0)
    )
    let unwrappedBoundary = try #require(boundary, "expected a green-to-yellow transition somewhere in the output")
    #expect(
        abs(unwrappedBoundary - 0.5) < 0.08,
        "color boundary landed at \(unwrappedBoundary) instead of ~0.5 — content was stretched vertically"
    )
}

@Test func ffmpegEngineConvertsMovToGif() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let sourceSize = CGSize(width: 320, height: 240)
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: sourceSize, fps: 10, duration: 2.0)

    let probed = try await MediaFileProber.probe(url: sourceURL)

    let settings = GifSettings(
        fps: .fps(5),
        scale: .original,
        trim: .full(duration: probed.duration),
        crop: nil,
        paletteSize: .colors(64),
        dither: .bayer,
        loop: .forever
    )

    let outputURL = tempDir.appendingPathComponent("output.gif")
    let engine = FFmpegEngine()
    let job = engine.convert(probed, to: .gif, settings: .gif(settings), outputURL: outputURL)

    for await _ in await job.progress {}

    guard case .completed(let resultURL) = await job.state else {
        Issue.record("expected job to complete, got \(await job.state)")
        return
    }
    #expect(resultURL == outputURL)

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(outputProbe.resolution.width == 320)
    #expect(outputProbe.resolution.height == 240)
    #expect(outputProbe.duration > 0)
}

/// Regression: gif's palette filter graph buffers everything and emits
/// nothing until EOF, so progress used to stay pinned at 0% until a final
/// burst at 100% (see transcode.c's per-decoded-frame progress reporting).
@Test func ffmpegEngineGifConversionReportsIncrementalProgress() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let sourceSize = CGSize(width: 320, height: 240)
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: sourceSize, fps: 10, duration: 3.0)

    let probed = try await MediaFileProber.probe(url: sourceURL)
    let settings = GifSettings(trim: .full(duration: probed.duration))

    let outputURL = tempDir.appendingPathComponent("output.gif")
    let engine = FFmpegEngine()
    let job = engine.convert(probed, to: .gif, settings: .gif(settings), outputURL: outputURL)

    var progressValues: [Double] = []
    for await value in await job.progress {
        progressValues.append(value)
    }

    guard case .completed = await job.state else {
        Issue.record("expected job to complete, got \(await job.state)")
        return
    }

    #expect(progressValues.count > 2, "expected multiple progress updates, not a jump straight to completion")
    #expect(
        progressValues.contains(where: { $0 > 0.2 && $0 < 0.8 }),
        "expected a mid-range progress update; got \(progressValues)"
    )
}

@Test func ffmpegEngineCancelDeletesPartialOutput() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let sourceSize = CGSize(width: 320, height: 240)
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: sourceSize, fps: 10, duration: 5.0)

    let probed = try await MediaFileProber.probe(url: sourceURL)
    let settings = VideoSettings(trim: .full(duration: probed.duration))
    let outputURL = tempDir.appendingPathComponent("output.webm")

    let engine = FFmpegEngine()
    let job = engine.convert(probed, to: .webm, settings: .video(settings), outputURL: outputURL)
    await job.cancel()

    try await Task.sleep(for: .milliseconds(1000))

    if case .failed = await job.state {
        Issue.record("cancel should not surface as failure")
    }
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
}
