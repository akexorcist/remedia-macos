import Testing
import Foundation
import CoreGraphics
import CoreMedia
@testable import RemediaCore

@Test func avFoundationEngineRespectsExplicitVideoCodecChoice() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: CGSize(width: 320, height: 240), fps: 10, duration: 1.0)
    let probed = try await MediaFileProber.probe(url: sourceURL)
    let engine = AVFoundationEngine()

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

/// `.customWidth` (unlike `.scale`) had never been exercised by any test —
/// including from the UI, since there was no control for it at all until
/// `ResolutionPickerRow`'s width/height fields.
@Test func avFoundationEngineAppliesCustomWidthResolution() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: CGSize(width: 640, height: 480), fps: 10, duration: 1.0)
    let probed = try await MediaFileProber.probe(url: sourceURL)

    // 640x480 (4:3) at customWidth(321) -> raw 321x240.75, then
    // OutputSizeResolver's even-dimension floor -> 320x240.
    let settings = VideoSettings(
        resolution: .customWidth(321), trim: TrimRange(start: 0, end: 1.0), audio: .stripped
    )
    let outputURL = tempDir.appendingPathComponent("output.mp4")
    let engine = AVFoundationEngine()
    let job = engine.convert(probed, to: .mp4, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete")
        return
    }

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(outputProbe.resolution.width == 320)
    #expect(outputProbe.resolution.height == 240)
}

@Test func avFoundationEngineAppliesTrimCropAndScale() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let sourceSize = CGSize(width: 640, height: 480)
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: sourceSize, fps: 10, duration: 4.0)

    let probed = try await MediaFileProber.probe(url: sourceURL)
    #expect(probed.format == .mov)
    #expect(abs(probed.duration - 4.0) < 0.2)
    #expect(probed.resolution == sourceSize)

    // 300x200 crop out of the 640x480 source, then scaled 0.5x -> 150x100,
    // trimmed to the [1s, 3s] range -> 2s output, audio stripped.
    let settings = VideoSettings(
        quality: 60,
        resolution: .scale(0.5),
        frameRate: .original,
        trim: TrimRange(start: 1.0, end: 3.0),
        crop: CGRect(x: 100, y: 50, width: 300, height: 200),
        audio: .stripped
    )

    let outputURL = tempDir.appendingPathComponent("output.mp4")
    let engine = AVFoundationEngine()
    let job = engine.convert(probed, to: .mp4, settings: .video(settings), outputURL: outputURL)

    var lastProgress = 0.0
    for await value in await job.progress {
        lastProgress = value
    }
    #expect(lastProgress > 0)

    guard case .completed(let resultURL) = await job.state else {
        Issue.record("expected job to complete")
        return
    }
    #expect(resultURL == outputURL)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(abs(outputProbe.duration - 2.0) < 0.3)
    #expect(outputProbe.resolution.width == 150)
    #expect(outputProbe.resolution.height == 100)
    #expect(outputProbe.hasAudio == false)
}

/// Regression: the crop+scale pipeline used to scale against the actual
/// (post-`.intersection`) cropped extent instead of the requested crop
/// size — a mismatch invisible to dimension checks, only visible in pixel
/// content, and most likely for an edge-touching crop like the UI's
/// aspect-ratio presets produce.
@Test func avFoundationEngineEdgeTouchingCropDoesNotStretchContent() async throws {
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

    let outputURL = tempDir.appendingPathComponent("output.mp4")
    let engine = AVFoundationEngine()
    let job = engine.convert(probed, to: .mp4, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete")
        return
    }

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(outputProbe.resolution.width == 200)
    #expect(outputProbe.resolution.height == 300)

    let frame = try await FramePixelInspector.firstFrame(of: outputURL, format: .mp4)
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

/// Same regression, for a rotated source: a portrait-recorded video stores
/// a landscape buffer with a 90° `preferredTransform` rather than rotated
/// pixels, and `request.sourceImage`'s extent may not have origin (0,0)
/// once that's folded in — assuming otherwise mis-locates the crop.
@Test func avFoundationEngineEdgeTouchingCropDoesNotStretchRotatedSource() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let rawSize = CGSize(width: 400, height: 300)
    // Standard iPhone-style 90° CW portrait transform: a landscape pixel
    // buffer displayed as 300x400 portrait.
    let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rawSize.height, ty: 0)
    try await SyntheticMovie.makeQuadrantMovie(url: sourceURL, size: rawSize, fps: 5, duration: 1.0, transform: transform)

    let probed = try await MediaFileProber.probe(url: sourceURL)
    #expect(probed.resolution == CGSize(width: 300, height: 400))

    // Top half of the displayed (300x400) source: holds the raw bottom-left
    // quadrant (blue) on the left and raw top-left quadrant (red) on the
    // right, split at the horizontal midpoint (confirmed empirically).
    let settings = VideoSettings(
        quality: 80,
        resolution: .original,
        frameRate: .original,
        trim: .full(duration: 1.0),
        crop: CGRect(x: 0, y: 0, width: 300, height: 200),
        audio: .stripped
    )

    let outputURL = tempDir.appendingPathComponent("output.mp4")
    let engine = AVFoundationEngine()
    let job = engine.convert(probed, to: .mp4, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete")
        return
    }

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(outputProbe.resolution.width == 300)
    #expect(outputProbe.resolution.height == 200)

    let frame = try await FramePixelInspector.firstFrame(of: outputURL, format: .mp4)
    let boundary = FramePixelInspector.colorBoundaryFraction(
        in: frame, row: frame.height / 2,
        from: (0, 0, 255), to: (255, 0, 0)
    )
    let unwrappedBoundary = try #require(boundary, "expected a blue-to-red transition somewhere in the output")
    #expect(
        abs(unwrappedBoundary - 0.5) < 0.08,
        "color boundary landed at \(unwrappedBoundary) instead of ~0.5 — rotated-source crop was stretched horizontally"
    )
}

/// Regression for a real user-reported bug: a non-square-pixel (SAR) source
/// got its crop shifted/stretched, because `AVAssetImageGenerator` (used for
/// `MediaFile.resolution`, and so the crop overlay) folds SAR into its
/// reported size, but `AVVideoComposition`'s `request.sourceImage` doesn't —
/// it decodes at the raw, un-stretched storage size instead.
@Test func avFoundationEngineAnamorphicSourceDoesNotShiftOrStretchCrop() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    // 320x240 (4:3) storage grid, stretched by its 4:3 PAR to display at
    // 426.667x240 (16:9) — the mismatch shape from the real report.
    let encodedSize = CGSize(width: 320, height: 240)
    try await SyntheticMovie.makeAnamorphicQuadrantMovie(
        url: sourceURL, encodedSize: encodedSize, pixelAspectRatio: (horizontal: 4, vertical: 3),
        fps: 5, duration: 1.0
    )

    let probed = try await MediaFileProber.probe(url: sourceURL)
    #expect(abs(probed.resolution.width - 426.667) < 1, "expected the SAR-corrected display width, not the raw 320")
    #expect(probed.resolution.height == 240)

    // Straddles the display-space quadrant boundary (213.333) asymmetrically:
    // expected fraction ≈56.7%; misread against the raw 320-wide frame
    // (boundary at column 160) it would land at 30% instead.
    let settings = VideoSettings(
        quality: 80,
        resolution: .original,
        frameRate: .original,
        trim: .full(duration: 1.0),
        crop: CGRect(x: 100, y: 0, width: 200, height: 240),
        audio: .stripped
    )

    let outputURL = tempDir.appendingPathComponent("output.mp4")
    let engine = AVFoundationEngine()
    let job = engine.convert(probed, to: .mp4, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete")
        return
    }

    // Row within the top half, where the crop's content transitions from
    // the top-left quadrant (red) to the top-right quadrant (green).
    let frame = try await FramePixelInspector.firstFrame(of: outputURL, format: .mp4)
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

@Test func avFoundationEngineCancelDeletesPartialOutput() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sourceURL = tempDir.appendingPathComponent("source.mov")
    let sourceSize = CGSize(width: 320, height: 240)
    try await SyntheticMovie.makeSolidColorMovie(url: sourceURL, size: sourceSize, fps: 10, duration: 5.0)

    let probed = try await MediaFileProber.probe(url: sourceURL)
    let settings = VideoSettings(trim: .full(duration: probed.duration))
    let outputURL = tempDir.appendingPathComponent("output.mp4")

    let engine = AVFoundationEngine()
    let job = engine.convert(probed, to: .mp4, settings: .video(settings), outputURL: outputURL)
    await job.cancel()

    // Give the reader/writer loop a moment to observe cancellation and exit.
    try await Task.sleep(for: .milliseconds(500))

    if case .failed = await job.state {
        Issue.record("cancel should not surface as failure")
    }
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
}
