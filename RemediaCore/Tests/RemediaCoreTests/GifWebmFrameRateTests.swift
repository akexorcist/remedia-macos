import Testing
import Foundation
import CoreGraphics
@testable import RemediaCore

/// Regression coverage for the gif→webm crash: a gif-sourced webm commonly
/// has `avg_frame_rate = 0/0`, and `av_q2d` of that is NaN — which
/// `cffmpeg_probe`'s old `frameRate <= 0` check let through uncaught (NaN
/// comparisons are always false). That NaN reached `ResultPlayerView`'s
/// frame-interval `UInt64(Double)` conversion and crashed the app.
@Test func gifToWebmConversionNeverReportsNonFiniteFrameRate() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let gifURL = tempDir.appendingPathComponent("source.gif")
    try SyntheticGIF.makeQuadrantGIF(url: gifURL, size: CGSize(width: 100, height: 100), frameCount: 4, frameDelay: 0.1)
    let gifFile = try await MediaFileProber.probe(url: gifURL)

    let webmURL = tempDir.appendingPathComponent("out.webm")
    let settings = VideoSettings(trim: .full(duration: gifFile.duration))
    let job = FFmpegEngine().convert(gifFile, to: .webm, settings: .video(settings), outputURL: webmURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("gif -> webm conversion failed: \(await job.state)")
        return
    }

    let outputProbe = try await MediaFileProber.probe(url: webmURL)
    #expect(outputProbe.frameRate.isFinite, "frameRate must never be NaN/infinite — it flows into a UInt64(Double) conversion downstream")
    #expect(outputProbe.frameRate > 0, "frameRate must be positive — zero or negative would divide-by-zero downstream")
}
