import AVFoundation
import RemediaCore

/// `MediaFile` (the production-facing probe result) doesn't expose codec
/// identity at all — nothing downstream needs it — so tests that care read
/// it directly via AVFoundation instead of adding test-only API surface to
/// the real prober.
enum VideoCodecInspector {
    enum InspectionError: Error {
        case noVideoTrack
        case noFormatDescription
    }

    static func videoCodec(of url: URL) async throws -> CMVideoCodecType {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw InspectionError.noVideoTrack
        }
        guard let formatDescription = try await track.load(.formatDescriptions).first else {
            throw InspectionError.noFormatDescription
        }
        return CMFormatDescriptionGetMediaSubType(formatDescription)
    }

    /// HEVC-in-MP4 legitimately has two standard sample-entry tags — "hvc1"
    /// (parameter sets out-of-band, what AVFoundation's own encoder writes)
    /// and "hev1" (inline, what FFmpeg's mp4 muxer writes for
    /// hevc_videotoolbox) — both are genuinely HEVC, just a muxer choice,
    /// so a codec-identity check needs to accept either.
    static func acceptableFourCCs(for codec: VideoCodec) -> Set<CMVideoCodecType> {
        switch codec {
        case .auto, .h264: return [kCMVideoCodecType_H264]
        case .hevc: return [kCMVideoCodecType_HEVC, fourCC("hev1")]
        }
    }

    private static func fourCC(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
