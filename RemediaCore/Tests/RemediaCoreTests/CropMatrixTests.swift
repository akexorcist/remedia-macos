import Testing
import Foundation
import CoreGraphics
@testable import RemediaCore

/// Depth companion to `ConversionMatrixTests`' breadth: proves a crop lands
/// at the correct pixel position for every source/target format pair, not
/// just that the pair converts successfully. Each fixture is a quadrant-
/// colored image/video; the crop straddles the quadrant boundary
/// asymmetrically, so a shift/stretch bug moves it to a clearly wrong
/// fraction rather than one a coincidental symmetry could mask.
private enum CropMatrixFixture {
    static let sourceSize = CGSize(width: 320, height: 240)
    static let fps: Int32 = 10
    static let duration = 1.0

    static let cropX: CGFloat = 60
    static let cropWidth: CGFloat = 180
    // 160 = sourceSize.width / 2, the quadrant boundary column.
    static let expectedBoundaryFraction = (160.0 - Double(cropX)) / Double(cropWidth)

    static func make(format: OutputFormat, in directory: URL) async throws -> MediaFile {
        switch format {
        case .mov:
            let url = directory.appendingPathComponent("source.mov")
            try await SyntheticMovie.makeQuadrantMovie(url: url, size: sourceSize, fps: fps, duration: duration, fileType: .mov)
            return try await MediaFileProber.probe(url: url)

        case .mp4:
            let url = directory.appendingPathComponent("source.mp4")
            try await SyntheticMovie.makeQuadrantMovie(url: url, size: sourceSize, fps: fps, duration: duration, fileType: .mp4)
            return try await MediaFileProber.probe(url: url)

        case .gif:
            let url = directory.appendingPathComponent("source.gif")
            try SyntheticGIF.makeQuadrantGIF(url: url, size: sourceSize, frameCount: 4, frameDelay: duration / 4)
            return try await MediaFileProber.probe(url: url)

        case .webm:
            // Bootstrapped via FFmpegEngine like ConversionMatrixTests'
            // webm source, exercising decode independently of encode.
            let movURL = directory.appendingPathComponent("bootstrap.mov")
            try await SyntheticMovie.makeQuadrantMovie(url: movURL, size: sourceSize, fps: fps, duration: duration)
            let movFile = try await MediaFileProber.probe(url: movURL)

            let webmURL = directory.appendingPathComponent("source.webm")
            let settings = VideoSettings(trim: .full(duration: movFile.duration))
            let job = FFmpegEngine().convert(movFile, to: .webm, settings: .video(settings), outputURL: webmURL)
            for await _ in await job.progress {}
            guard case .completed = await job.state else {
                Issue.record("webm source fixture bootstrap failed: \(await job.state)")
                throw MediaProbeError.unreadableImageSource
            }
            return try await MediaFileProber.probe(url: webmURL)
        }
    }
}

/// All 16 source/target pairs (see GifWebmFrameRateTests for the gif→webm
/// crash this used to exclude).
private let cropMatrixPairs: [(source: OutputFormat, target: OutputFormat)] = {
    OutputFormat.allCases.flatMap { source in
        OutputFormat.allCases.map { target in (source, target) }
    }
}()

@Test(arguments: cropMatrixPairs)
func cropMatrix(pair: (source: OutputFormat, target: OutputFormat)) async throws {
    let (sourceFormat, targetFormat) = pair
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let source = try await CropMatrixFixture.make(format: sourceFormat, in: tempDir)

    let crop = CGRect(x: CropMatrixFixture.cropX, y: 0, width: CropMatrixFixture.cropWidth, height: CropMatrixFixture.sourceSize.height)
    let settings: ConversionSettings = targetFormat == .gif
        ? .gif(GifSettings(trim: .full(duration: source.duration), crop: crop))
        : .video(VideoSettings(trim: .full(duration: source.duration), crop: crop))

    let outputURL = tempDir.appendingPathComponent("output.\(targetFormat.fileExtension)")
    let engine = EngineRouter.engine(source: sourceFormat, target: targetFormat)
    let job = engine.convert(source, to: targetFormat, settings: settings, outputURL: outputURL)

    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("\(sourceFormat.rawValue) -> \(targetFormat.rawValue): \(await job.state)")
        return
    }

    let frame = try await FramePixelInspector.firstFrame(of: outputURL, format: targetFormat)
    // Row within the top half, where quadrant content transitions from red
    // (top-left) to green (top-right).
    let boundary = FramePixelInspector.colorBoundaryFraction(
        in: frame, row: frame.height / 4,
        from: (255, 0, 0), to: (0, 255, 0)
    )
    let unwrappedBoundary = try #require(
        boundary, "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): expected a red-to-green transition in the output"
    )
    #expect(
        abs(unwrappedBoundary - CropMatrixFixture.expectedBoundaryFraction) < 0.1,
        "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): color boundary landed at \(unwrappedBoundary), expected ~\(CropMatrixFixture.expectedBoundaryFraction) — crop was shifted/stretched"
    )
}
