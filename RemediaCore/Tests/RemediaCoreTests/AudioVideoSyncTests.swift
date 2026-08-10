import Testing
import Foundation
import AVFoundation
@testable import RemediaCore

/// Regression: AVFoundationEngine rebased video's presentation timestamps by
/// -trim.start but left audio sample buffers unmodified, so any non-zero
/// trim.start left the output's audio starting late relative to video.
/// Fixed via `AVFoundationEngine.sampleBuffer(_:shiftedBy:)`.
///
/// Uses the real mov fixture, not `SyntheticMovie` — it has no audio track,
/// so this bug (needs real audio + non-zero trim) went uncaught before.
@Test func avFoundationEngineTrimKeepsAudioAndVideoTracksSynced() async throws {
    guard let fixtureURL = Bundle.module.url(forResource: "sample_video", withExtension: "mov", subdirectory: "Fixtures") else {
        Issue.record("sample_video.mov fixture not found")
        return
    }

    let source = try await MediaFileProber.probe(url: fixtureURL)
    #expect(source.hasAudio, "this regression test requires a fixture with audio")

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Non-zero trim.start is what exposes the bug — a couple of seconds in,
    // stopping well before the fixture's ~5.6s end.
    let trimStart = 2.0
    let trimEnd = min(4.0, source.duration - 0.1)
    let settings = VideoSettings(trim: TrimRange(start: trimStart, end: trimEnd))

    let outputURL = tempDir.appendingPathComponent("output.mp4")
    let job = AVFoundationEngine().convert(source, to: .mp4, settings: .video(settings), outputURL: outputURL)
    for await _ in await job.progress {}

    guard case .completed = await job.state else {
        Issue.record("conversion failed: \(await job.state)")
        return
    }

    let outputAsset = AVURLAsset(url: outputURL)
    guard let outputVideoTrack = try await outputAsset.loadTracks(withMediaType: .video).first,
          let outputAudioTrack = try await outputAsset.loadTracks(withMediaType: .audio).first
    else {
        Issue.record("expected both a video and audio track in the output")
        return
    }

    // Track-level `timeRange` reports start=0 by convention without an edit
    // list, regardless of what was appended — read real sample timestamps
    // via AVAssetReader instead.
    let reader = try AVAssetReader(asset: outputAsset)
    let videoOutput = AVAssetReaderTrackOutput(track: outputVideoTrack, outputSettings: nil)
    let audioOutput = AVAssetReaderTrackOutput(track: outputAudioTrack, outputSettings: nil)
    reader.add(videoOutput)
    reader.add(audioOutput)
    guard reader.startReading() else {
        Issue.record("could not read back the output file: \(String(describing: reader.error))")
        return
    }

    func firstPresentationSeconds(_ output: AVAssetReaderTrackOutput) -> Double? {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetPresentationTimeStamp(sample).seconds
    }

    let videoStart = firstPresentationSeconds(videoOutput)
    let audioStart = firstPresentationSeconds(audioOutput)

    #expect(videoStart != nil, "expected at least one video sample in the output")
    #expect(audioStart != nil, "expected at least one audio sample in the output")

    // Both tracks' first real samples should land at (approximately) the
    // same point in the output's own timeline — not off by anything close
    // to trimStart (2.0s), which is what the bug produced.
    if let videoStart, let audioStart {
        #expect(videoStart < 0.1, "video's first sample should be near 0, got \(videoStart)")
        #expect(audioStart < 0.1, "audio's first sample should be near 0, got \(audioStart) — this is the exact symptom of the trim-shift bug")
        #expect(abs(videoStart - audioStart) < 0.1, "video (\(videoStart)) and audio (\(audioStart)) first samples drifted apart by trim shift")
    }

    attachOutputToTestReport(at: outputURL, named: "avfoundation-trim-sync-check.mp4")
}
