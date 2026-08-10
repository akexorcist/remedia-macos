import Foundation

/// Single routing rule shared by conversion and preview source selection
/// (ARCHITECTURE §3): mov <-> mp4 stays native; anything touching gif or
/// webm goes through FFmpeg.
public enum EngineRouter {
    private static let nativeFormats: Set<OutputFormat> = [.mov, .mp4]

    public static func isNativePair(source: OutputFormat, target: OutputFormat) -> Bool {
        nativeFormats.contains(source) && nativeFormats.contains(target)
    }

    public static func engine(source: OutputFormat, target: OutputFormat) -> ConversionEngine {
        isNativePair(source: source, target: target) ? AVFoundationEngine() : FFmpegEngine()
    }

    public static func previewSource(for mediaFile: MediaFile) -> PreviewSource {
        nativeFormats.contains(mediaFile.format)
            ? AVPlayerPreviewSource(mediaFile: mediaFile)
            : FFmpegDecodePreviewSource(mediaFile: mediaFile)
    }
}
