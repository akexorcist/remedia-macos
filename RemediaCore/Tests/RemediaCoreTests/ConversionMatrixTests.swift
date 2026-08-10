import Testing
import Foundation
import CoreGraphics
@testable import RemediaCore

/// Breadth, not depth (docs/CONVERSION_MATRIX_TEST_PLAN.md): proves every
/// one of the 16 source/target pairs produces a valid, probeable output.
/// Crop/trim/scale correctness is already covered per-engine by
/// AVFoundationEngineTests/FFmpegEngineTests — this suite would only ever
/// tell you "this pair is broken," not "which setting broke it."
private enum ConversionMatrixFixture {
    static let sourceSize = CGSize(width: 320, height: 240)
    static let fps: Int32 = 10
    static let duration = 1.0

    static func make(format: OutputFormat, in directory: URL) async throws -> MediaFile {
        switch format {
        case .mov:
            let url = directory.appendingPathComponent("source.mov")
            try await SyntheticMovie.makeSolidColorMovie(url: url, size: sourceSize, fps: fps, duration: duration, fileType: .mov)
            return try await MediaFileProber.probe(url: url)

        case .mp4:
            let url = directory.appendingPathComponent("source.mp4")
            try await SyntheticMovie.makeSolidColorMovie(url: url, size: sourceSize, fps: fps, duration: duration, fileType: .mp4)
            return try await MediaFileProber.probe(url: url)

        case .gif:
            let url = directory.appendingPathComponent("source.gif")
            try SyntheticGIF.makeSolidColorGIF(url: url, size: sourceSize, frameCount: 8, frameDelay: duration / 8)
            return try await MediaFileProber.probe(url: url)

        case .webm:
            // Bootstrapped via our own encoder to exercise webm as a
            // *source* (decode/demux), a different code path than encoding
            // — see the test plan doc for why this isn't circular.
            let movURL = directory.appendingPathComponent("bootstrap.mov")
            try await SyntheticMovie.makeSolidColorMovie(url: movURL, size: sourceSize, fps: fps, duration: duration)
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

@Test(arguments: OutputFormat.allCases, OutputFormat.allCases)
func conversionMatrix(sourceFormat: OutputFormat, targetFormat: OutputFormat) async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let source = try await ConversionMatrixFixture.make(format: sourceFormat, in: tempDir)

    // Minimal settings deliberately — full trim, no crop, original
    // resolution/fps, auto audio. Same-format pairs (mov->mov, etc.)
    // exercise REQUIREMENTS §4's edit-only re-encode path, not an oversight.
    let settings: ConversionSettings = targetFormat == .gif
        ? .gif(GifSettings(trim: .full(duration: source.duration)))
        : .video(VideoSettings(trim: .full(duration: source.duration)))

    let outputURL = tempDir.appendingPathComponent("output.\(targetFormat.fileExtension)")
    let engine = EngineRouter.engine(source: sourceFormat, target: targetFormat)
    let job = engine.convert(source, to: targetFormat, settings: settings, outputURL: outputURL)

    for await _ in await job.progress {}

    guard case .completed(let resultURL) = await job.state else {
        Issue.record("\(sourceFormat.rawValue) -> \(targetFormat.rawValue) failed: \(await job.state)")
        return
    }
    #expect(resultURL == outputURL)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(outputProbe.duration > 0, "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): zero duration")

    // Encoders round dimensions to even numbers, so allow a little slack.
    #expect(
        abs(outputProbe.resolution.width - ConversionMatrixFixture.sourceSize.width) <= 2,
        "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): width \(outputProbe.resolution.width)"
    )
    #expect(
        abs(outputProbe.resolution.height - ConversionMatrixFixture.sourceSize.height) <= 2,
        "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): height \(outputProbe.resolution.height)"
    )

    // Embedded into the test report (Xcode's Report Navigator) so the
    // actual converted file can be opened/exported, not just trusted on the
    // numeric assertions above — attached before `defer` deletes tempDir.
    attachOutputToTestReport(
        at: outputURL,
        named: "\(sourceFormat.rawValue)-to-\(targetFormat.rawValue).\(targetFormat.fileExtension)"
    )
}
