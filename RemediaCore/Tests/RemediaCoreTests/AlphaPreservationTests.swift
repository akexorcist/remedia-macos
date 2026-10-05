import Testing
import Foundation
import CoreGraphics
import CoreVideo
import CFFmpeg
@testable import RemediaCore

/// Regression coverage for the vp8/vp9 webm alpha bug: FFmpeg's native vp9
/// decoder silently drops the Matroska "BlockAdditional" alpha side data
/// WebM uses to carry transparency, and even the alpha-aware libvpx-wrapped
/// decoder only learns a stream has it after decoding a real frame — so
/// `cffmpeg_open_decoder` both prefers that decoder for vp8/vp9 and peeks
/// one frame (then rewinds) to force that detection before any caller
/// builds pix_fmt-dependent state. These tests don't re-derive that via
/// pixel-level alpha inspection (see FFmpegDecodePreviewSourceTests for
/// that) — they guard the two edges the fix could plausibly get wrong:
/// turning alpha on for sources that never had it, and choking on an
/// alpha-capable source once alpha can't survive the target format.
private enum AlphaWebmFixture {
    /// Built directly via `cffmpeg_encode_synthetic_alpha_webm` rather than
    /// through `FFmpegEngine` — nothing in the production pipeline can
    /// produce alpha from scratch, only preserve it from an alpha-bearing
    /// source, so there's no engine call that could create this starting
    /// point.
    static func make(in directory: URL, width: Int = 64, height: Int = 48, frameCount: Int = 2) async throws -> MediaFile {
        let url = directory.appendingPathComponent("alpha.webm")
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = url.path.withCString { outputC in
            errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                cffmpeg_encode_synthetic_alpha_webm(
                    outputC, Int32(width), Int32(height), Int32(frameCount),
                    errorPtr.baseAddress, Int32(errorPtr.count)
                )
            }
        }
        guard status == 0 else {
            Issue.record("synthesizing alpha webm fixture failed: \(String(cString: errorBuffer))")
            throw MediaProbeError.unreadableImageSource
        }
        return try await MediaFileProber.probe(url: url)
    }
}

/// Non-regression guard: an ordinary opaque webm source must not come out
/// the other side with visible transparency introduced. (The fixture
/// itself turns out to already carry a nominal, always-opaque alpha
/// channel — `ffprobe` only reveals that when forced through the
/// alpha-aware `libvpx-vp9` decoder, same as the bug this suite guards —
/// so this doesn't assert the output's encoded pix_fmt, only that nothing
/// ever decodes as actually transparent.)
@Test func ffmpegEngineOpaqueWebmSourceStaysFullyOpaqueAfterWebmConversion() async throws {
    guard let sourceURL = Bundle.module.url(forResource: "sample_video", withExtension: "webm", subdirectory: "Fixtures") else {
        Issue.record("missing sample_video.webm fixture")
        return
    }
    let source = try await MediaFileProber.probe(url: sourceURL)

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let outputURL = tempDir.appendingPathComponent("output.webm")
    let settings = VideoSettings(trim: .full(duration: source.duration))
    let job = FFmpegEngine().convert(source, to: .webm, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete, got \(await job.state)")
        return
    }

    let resultMediaFile = try await MediaFileProber.probe(url: outputURL)
    let previewSource = FFmpegDecodePreviewSource(mediaFile: resultMediaFile)
    let frame = try await previewSource.frame(at: 0)

    CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(frame.pixelBuffer)?.assumingMemoryBound(to: UInt8.self))
    let bytesPerRow = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
    let width = CVPixelBufferGetWidth(frame.pixelBuffer)
    let height = CVPixelBufferGetHeight(frame.pixelBuffer)

    var minAlpha: UInt8 = 255
    for row in 0..<height {
        for col in 0..<width {
            minAlpha = min(minAlpha, base[row * bytesPerRow + col * 4 + 3])
        }
    }
    #expect(minAlpha == 255, "a source with no alpha at all should never decode with transparent pixels after conversion")
}

/// Target-gating guard: h264/hevc (mp4/mov) can't carry alpha in this
/// pipeline, so an alpha-bearing webm source converting to mp4 must still
/// complete cleanly as a plain opaque frame — not error out or corrupt the
/// filter graph from decoderCtx->pix_fmt (now yuva420p) disagreeing with
/// the encoder's hardcoded yuv420p.
@Test func ffmpegEngineAlphaWebmSourceConvertsCleanlyToMp4() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let source = try await AlphaWebmFixture.make(in: tempDir)

    let outputURL = tempDir.appendingPathComponent("output.mp4")
    let settings = VideoSettings(trim: .full(duration: source.duration))
    let job = FFmpegEngine().convert(source, to: .mp4, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}
    guard case .completed = await job.state else {
        Issue.record("expected job to complete, got \(await job.state)")
        return
    }

    let frame = try await FramePixelInspector.firstFrame(of: outputURL, format: .mp4)
    let leftPixel = frame.pixel(x: frame.width / 4, y: frame.height / 2)
    #expect(
        leftPixel.r > 150 && leftPixel.g < 100 && leftPixel.b < 100,
        "expected the fixture's solid-red opaque half to survive conversion, got \(leftPixel)"
    )
}
