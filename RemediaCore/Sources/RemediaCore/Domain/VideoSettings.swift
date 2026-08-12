import Foundation
import CoreGraphics

/// Advanced settings for mp4/mov/webm output (REQUIREMENTS §6).
public struct VideoSettings: Sendable, Equatable {
    /// 50...100 in the UI (5% steps, matching GifSettings.quality) — mapped
    /// internally to a bitrate heuristic (or CRF-equivalent) per codec. Not
    /// clamped here, so engine/test code can exercise values outside the
    /// UI's range.
    public var quality: Double
    public var resolution: ResolutionOverride
    public var frameRate: FrameRateOverride
    public var trim: TrimRange
    /// Defined in the source's original, uncropped resolution (ARCHITECTURE §6).
    /// `nil` means no crop.
    public var crop: CGRect?
    public var audio: AudioMode
    /// mp4/mov only (REQUIREMENTS §6) — ignored for a webm target, which is
    /// always libvpx-vp9 regardless of this value.
    public var videoCodec: VideoCodec

    public init(
        quality: Double = 85,
        resolution: ResolutionOverride = .original,
        frameRate: FrameRateOverride = .original,
        trim: TrimRange,
        crop: CGRect? = nil,
        audio: AudioMode = .auto,
        videoCodec: VideoCodec = .auto
    ) {
        self.quality = quality
        self.resolution = resolution
        self.frameRate = frameRate
        self.trim = trim
        self.crop = crop
        self.audio = audio
        self.videoCodec = videoCodec
    }
}
