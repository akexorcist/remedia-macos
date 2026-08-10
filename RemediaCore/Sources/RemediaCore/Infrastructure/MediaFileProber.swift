import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import CFFmpeg

public enum MediaProbeError: Error, Sendable {
    case unrecognizedExtension
    case noVideoTrack
    case unreadableImageSource
    case ffmpegProbeFailed(code: Int32, message: String)
}

/// Probes a dropped file for the metadata the rest of the app needs
/// (ARCHITECTURE §4 step 1). mov/mp4 use AVFoundation; gif uses ImageIO (no
/// FFmpeg needed for either — just reading metadata, not encoding); webm has
/// no native probing path at all and uses the vendored FFmpeg bridge.
public enum MediaFileProber {
    public static func probe(url: URL) async throws -> MediaFile {
        guard let format = OutputFormat(fileExtension: url.pathExtension) else {
            throw MediaProbeError.unrecognizedExtension
        }

        switch format {
        case .mov, .mp4:
            return try await probeWithAVFoundation(url: url, format: format)
        case .gif:
            return try probeGIF(url: url, format: format)
        case .webm:
            return try probeWithFFmpeg(url: url, format: format)
        }
    }

    private static func probeWithFFmpeg(url: URL, format: OutputFormat) throws -> MediaFile {
        var result = CFFmpegProbeResult(duration: 0, width: 0, height: 0, frameRate: 0, hasAudio: 0)
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let status = url.path.withCString { pathC in
            errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                withUnsafeMutablePointer(to: &result) { resultPtr in
                    cffmpeg_probe(pathC, resultPtr, errorPtr.baseAddress, Int32(errorPtr.count))
                }
            }
        }

        guard status == 0 else {
            throw MediaProbeError.ffmpegProbeFailed(code: status, message: String(cString: errorBuffer))
        }

        return MediaFile(
            url: url,
            format: format,
            duration: result.duration,
            resolution: CGSize(width: Int(result.width), height: Int(result.height)),
            frameRate: result.frameRate,
            hasAudio: result.hasAudio != 0
        )
    }

    private static func probeWithAVFoundation(url: URL, format: OutputFormat) async throws -> MediaFile {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaProbeError.noVideoTrack
        }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Derived from an actually-rendered frame, not a hand-computed
        // `naturalSize.applying(preferredTransform)` — that bounding-box
        // math only correctly captures a clean 90°-multiple rotation, and
        // silently disagrees with what's rendered for anything else (e.g. a
        // combined scale+rotate), desyncing the crop overlay from the
        // pixels it's drawn over.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let firstFrame = try await generator.image(at: .zero).image
        let resolution = CGSize(width: firstFrame.width, height: firstFrame.height)

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let handRolledSize = naturalSize.applying(transform)
        let handRolledResolution = CGSize(width: abs(handRolledSize.width), height: abs(handRolledSize.height))
        CropDebugLog.log(
            "PROBE url=\(url.lastPathComponent) naturalSize=\(naturalSize) transform=\(transform) " +
            "handRolledResolution=\(handRolledResolution) imageGeneratorResolution=\(resolution) " +
            "firstFrame(width:height)=(\(firstFrame.width):\(firstFrame.height))"
        )

        return MediaFile(
            url: url,
            format: format,
            duration: CMTimeGetSeconds(duration),
            resolution: resolution,
            frameRate: Double(nominalFrameRate),
            hasAudio: !audioTracks.isEmpty
        )
    }

    private static func probeGIF(url: URL, format: OutputFormat) throws -> MediaFile {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaProbeError.unreadableImageSource
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0,
              let firstProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = firstProperties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = firstProperties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw MediaProbeError.unreadableImageSource
        }

        var totalDuration: Double = 0
        for index in 0..<frameCount {
            totalDuration += frameDelay(source: source, index: index)
        }

        let frameRate = totalDuration > 0 ? Double(frameCount) / totalDuration : 0

        return MediaFile(
            url: url,
            format: format,
            duration: totalDuration,
            resolution: CGSize(width: pixelWidth, height: pixelHeight),
            frameRate: frameRate,
            hasAudio: false
        )
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.1
        }
        let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let delay = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        return unclampedDelay ?? delay ?? 0.1
    }
}
