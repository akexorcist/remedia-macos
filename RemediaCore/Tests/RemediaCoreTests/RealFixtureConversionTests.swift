import Testing
import Foundation
import CoreGraphics
@testable import RemediaCore

/// Real-world companion to ConversionMatrixTests: same 16-pair breadth, but
/// sourced from actual sample_video.{mov,mp4,gif,webm} files, not synthetic
/// solid-color ones — these aren't interchangeable (different resolutions,
/// fractional widths, irregular frame rates), so assertions below compare
/// against each source's own probed values rather than a shared constant.
private enum RealFixture {
    enum Error: Swift.Error {
        case missing(OutputFormat)
    }

    static func url(for format: OutputFormat) throws -> URL {
        guard let url = Bundle.module.url(forResource: "sample_video", withExtension: format.fileExtension, subdirectory: "Fixtures") else {
            throw Error.missing(format)
        }
        return url
    }
}

/// Locks in each fixture's measured properties — isolates "probing broke"
/// from "conversion broke" if this fails, more specifically than the matrix
/// test below (which would also fail on a probe regression).
@Test(arguments: OutputFormat.allCases)
func realFixtureProbesSuccessfully(format: OutputFormat) async throws {
    let url = try RealFixture.url(for: format)
    let file = try await MediaFileProber.probe(url: url)

    #expect(file.duration > 5.0 && file.duration < 6.0, "\(format.rawValue): duration \(file.duration)")
    #expect(file.resolution.height == 240, "\(format.rawValue): height \(file.resolution.height)")
    #expect(file.frameRate > 25 && file.frameRate <= 30, "\(format.rawValue): frameRate \(file.frameRate)")

    if format == .gif {
        #expect(!file.hasAudio, "gif should never report audio")
    } else {
        #expect(file.hasAudio, "\(format.rawValue): expected the real fixture to have an audio track")
    }
}

@Test(arguments: OutputFormat.allCases, OutputFormat.allCases)
func realFixtureConversionMatrix(sourceFormat: OutputFormat, targetFormat: OutputFormat) async throws {
    let source = try await MediaFileProber.probe(url: RealFixture.url(for: sourceFormat))

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Full trim, no crop, original resolution/fps, auto audio — same
    // minimal-settings philosophy as ConversionMatrixTests (breadth, not
    // depth; crop/trim/scale correctness has its own dedicated tests).
    let settings: ConversionSettings = targetFormat == .gif
        ? .gif(GifSettings(trim: .full(duration: source.duration)))
        : .video(VideoSettings(trim: .full(duration: source.duration)))

    let outputURL = tempDir.appendingPathComponent("output.\(targetFormat.fileExtension)")
    let engine = EngineRouter.engine(source: sourceFormat, target: targetFormat)
    let job = engine.convert(source, to: targetFormat, settings: settings, outputURL: outputURL)

    for await _ in await job.progress {}

    guard case .completed(let resultURL) = await job.state else {
        Issue.record("\(sourceFormat.rawValue) -> \(targetFormat.rawValue) (real fixture) failed: \(await job.state)")
        return
    }
    #expect(resultURL == outputURL)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputProbe = try await MediaFileProber.probe(url: outputURL)
    #expect(outputProbe.duration > 0, "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): zero duration")

    // Generous tolerance: the mp4 fixture's own width is fractional
    // (426.667) before encoders even round to even numbers, and gif/webm
    // muxers round differently again.
    #expect(
        abs(outputProbe.resolution.width - source.resolution.width) <= 4,
        "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): width \(outputProbe.resolution.width) vs source \(source.resolution.width)"
    )
    #expect(
        abs(outputProbe.resolution.height - source.resolution.height) <= 4,
        "\(sourceFormat.rawValue) -> \(targetFormat.rawValue): height \(outputProbe.resolution.height) vs source \(source.resolution.height)"
    )

    attachOutputToTestReport(
        at: outputURL,
        named: "real-\(sourceFormat.rawValue)-to-\(targetFormat.rawValue).\(targetFormat.fileExtension)"
    )
}
