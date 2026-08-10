import Testing
import Foundation
@testable import RemediaCore

/// GifSettings.quality (added after user feedback that "Auto" always
/// produced near-maximum-size output) drives paletteSize/dither whenever
/// those are left at .auto. Uses the real fixture, not synthetic solid-color
/// content — dithering's effect on file size is much smaller on flat colors
/// than on real footage, so a synthetic source wouldn't meaningfully
/// exercise this.
@Test func gifQualitySliderMeaningfullyAffectsFileSize() async throws {
    guard let fixtureURL = Bundle.module.url(forResource: "sample_video", withExtension: "mov", subdirectory: "Fixtures") else {
        Issue.record("sample_video.mov fixture not found")
        return
    }
    let source = try await MediaFileProber.probe(url: fixtureURL)

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func convert(quality: Double, name: String) async throws -> Int {
        let settings = GifSettings(fps: .fps(15), trim: .full(duration: source.duration), quality: quality)
        let outputURL = tempDir.appendingPathComponent("\(name).gif")
        let job = FFmpegEngine().convert(source, to: .gif, settings: .gif(settings), outputURL: outputURL)
        for await _ in await job.progress {}
        guard case .completed = await job.state else {
            Issue.record("\(name) (quality=\(quality)) failed: \(await job.state)")
            return 0
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        return (attributes[.size] as? Int) ?? 0
    }

    let lowQualitySize = try await convert(quality: 0, name: "low")
    let highQualitySize = try await convert(quality: 100, name: "high")

    #expect(lowQualitySize > 0)
    #expect(highQualitySize > 0)
    // Not just "different" — meaningfully smaller. Empirically, no-dither
    // vs sierra2_4a alone was roughly a 35% difference on this fixture, plus
    // the palette shrinking from 256 to 32 colors on top of that.
    #expect(
        Double(lowQualitySize) < Double(highQualitySize) * 0.7,
        "low quality (\(lowQualitySize) bytes) should be meaningfully smaller than high quality (\(highQualitySize) bytes)"
    )
}
