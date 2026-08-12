import Foundation
import CFFmpeg
import CoreGraphics

public enum FFmpegConversionError: Error, Sendable {
    case unresolvedVideoSettings
    case transcodeFailed(code: Int32, message: String)
}

/// GIF/WebM conversion path — bundled FFmpeg linked in-process
/// (ARCHITECTURE §1/§3). `EngineRouter` routes here for any conversion
/// touching gif or webm, either direction — including e.g. webm -> mov or
/// gif -> mp4, where the *target* is a native container but the *source*
/// isn't natively readable.
///
/// The actual decode/filter/encode/mux pipeline lives in C
/// (Sources/CFFmpeg/transcode.c) — this type's job is purely resolving
/// `ConversionSettings` into concrete values the C side has no opinions
/// about, and bridging progress/cancellation to `ConversionJob`.
public struct FFmpegEngine: ConversionEngine {
    public init() {}

    public func convert(
        _ source: MediaFile,
        to target: OutputFormat,
        settings: ConversionSettings,
        outputURL: URL
    ) -> ConversionJob {
        let job = ConversionJob()
        Task {
            await job.trackPartialOutput(outputURL)
            do {
                try Self.run(source: source, target: target, settings: settings, outputURL: outputURL, job: job)
                if await job.isCancelledSync {
                    // cancel() can race the C side's own file creation, so
                    // the file may exist despite cancel() already "finishing".
                    try? FileManager.default.removeItem(at: outputURL)
                } else {
                    await job.complete(with: outputURL)
                }
            } catch {
                if await job.isCancelledSync {
                    try? FileManager.default.removeItem(at: outputURL)
                } else {
                    await job.fail(with: error)
                }
            }
        }
        return job
    }

    private static func run(
        source: MediaFile,
        target: OutputFormat,
        settings: ConversionSettings,
        outputURL: URL,
        job: ConversionJob
    ) throws {
        let crop: CGRect?
        let resolutionOverride: ResolutionOverride
        let frameRateOverride: FrameRateOverride
        let trim: TrimRange
        let isGifTarget = target == .gif

        switch settings {
        case .video(let videoSettings):
            crop = videoSettings.crop
            resolutionOverride = videoSettings.resolution
            frameRateOverride = videoSettings.frameRate
            trim = videoSettings.trim
        case .gif(let gifSettings):
            crop = gifSettings.crop
            resolutionOverride = gifSettings.scale
            frameRateOverride = gifSettings.fps
            trim = gifSettings.trim
        }

        let cropRect = crop ?? CGRect(origin: .zero, size: source.resolution)
        let outputSize = OutputSizeResolver.resolvedOutputSize(cropSize: cropRect.size, resolution: resolutionOverride)
        CropDebugLog.log(
            "FFMPEG.run url=\(source.url.lastPathComponent) target=\(target.rawValue) sourceSize(=source.resolution)=\(source.resolution) " +
            "requestedCrop=\(String(describing: crop)) effectiveCropRect=\(cropRect) outputSize=\(outputSize)"
        )
        let fps: Double = {
            switch frameRateOverride {
            case .original: return source.frameRate > 0 ? source.frameRate : 30
            case .fps(let value): return value
            }
        }()

        let audio: (codec: String, bitrateKbps: Int)? = {
            guard case .video(let videoSettings) = settings else { return nil }
            return audioCodecAndBitrate(for: target, mode: videoSettings.audio)
        }()

        let quality: Double = {
            guard case .video(let videoSettings) = settings else { return 0.7 }
            return max(min(videoSettings.quality, 100), 0) / 100.0
        }()

        var paletteColors: Int32 = 0
        var ditherMode: String?
        var gifLoopCount: Int32 = 0
        if case .gif(let gifSettings) = settings {
            switch gifSettings.paletteSize {
            case .auto: paletteColors = Int32(Self.autoPaletteColors(forQuality: gifSettings.quality))
            case .colors(let n): paletteColors = Int32(n)
            }
            switch gifSettings.dither {
            case .auto: ditherMode = Self.autoDitherMode(forQuality: gifSettings.quality)
            case .none: ditherMode = "none"
            case .bayer: ditherMode = "bayer"
            case .floydSteinberg: ditherMode = "floyd_steinberg"
            }
            switch gifSettings.loop {
            case .forever: gifLoopCount = 0
            case .once: gifLoopCount = -1
            case .times(let n): gifLoopCount = Int32(n)
            }
        }

        try invokeTranscode(
            inputPath: source.url.path,
            outputPath: outputURL.path,
            outputFormatName: target.rawValue,
            sourceSize: source.resolution,
            hasCrop: crop != nil,
            cropRect: cropRect,
            outputSize: outputSize,
            fps: fps,
            trim: trim,
            quality: quality,
            videoCodecName: videoCodecName(for: target, settings: settings),
            audio: audio,
            isGifTarget: isGifTarget,
            paletteColors: paletteColors,
            ditherMode: ditherMode,
            gifLoopCount: gifLoopCount,
            job: job
        )
    }

    private static func videoCodecName(for target: OutputFormat, settings: ConversionSettings) -> String {
        switch target {
        case .mov, .mp4:
            guard case .video(let videoSettings) = settings else { return "h264_videotoolbox" }
            switch videoSettings.videoCodec {
            case .auto, .h264: return "h264_videotoolbox"
            case .hevc: return "hevc_videotoolbox"
            }
        case .webm: return "libvpx-vp9"
        case .gif: return "gif"
        }
    }

    private static func audioCodecAndBitrate(for target: OutputFormat, mode: AudioMode) -> (codec: String, bitrateKbps: Int)? {
        switch mode {
        case .stripped:
            return nil
        case .auto:
            switch target {
            case .mov, .mp4: return ("aac", 128)
            case .webm: return ("libopus", 128)
            case .gif: return nil
            }
        case .custom(let codec, let bitrateKbps):
            switch codec {
            case .aac: return ("aac", bitrateKbps)
            case .alac: return ("alac", bitrateKbps)
            case .pcm: return ("pcm_s16le", bitrateKbps)
            case .opus: return ("libopus", bitrateKbps)
            case .vorbis: return ("vorbis", bitrateKbps)
            }
        }
    }

    /// 32...256 colors, linear in quality. Palette size is the single
    /// biggest lever GIF output has for trading size against banding —
    /// confirmed empirically (256→64 colors roughly halved file size on a
    /// real sample clip).
    private static func autoPaletteColors(forQuality quality: Double) -> Int {
        let normalized = max(min(quality, 100), 0) / 100.0
        return Int(32 + (256 - 32) * normalized)
    }

    /// Dithering reduces color-banding but measurably increases file size
    /// (roughly +35% on a real sample clip going from none to sierra2_4a) —
    /// disabled outright at low quality, lightweight (bayer) in the middle,
    /// and the heaviest/best (sierra2_4a) only above the two-thirds mark.
    private static func autoDitherMode(forQuality quality: Double) -> String {
        switch quality {
        case ..<33: return "none"
        case ..<66: return "bayer"
        default: return "sierra2_4a"
        }
    }

    private static func invokeTranscode(
        inputPath: String,
        outputPath: String,
        outputFormatName: String,
        sourceSize: CGSize,
        hasCrop: Bool,
        cropRect: CGRect,
        outputSize: CGSize,
        fps: Double,
        trim: TrimRange,
        quality: Double,
        videoCodecName: String,
        audio: (codec: String, bitrateKbps: Int)?,
        isGifTarget: Bool,
        paletteColors: Int32,
        ditherMode: String?,
        gifLoopCount: Int32,
        job: ConversionJob
    ) throws {
        let inputPathC = strdup(inputPath)
        let outputPathC = strdup(outputPath)
        let outputFormatNameC = strdup(outputFormatName)
        let videoCodecNameC = strdup(videoCodecName)
        let audioCodecNameC = audio.flatMap { strdup($0.codec) }
        let ditherModeC = ditherMode.flatMap { strdup($0) }
        defer {
            free(inputPathC)
            free(outputPathC)
            free(outputFormatNameC)
            free(videoCodecNameC)
            if let audioCodecNameC { free(audioCodecNameC) }
            if let ditherModeC { free(ditherModeC) }
        }

        // Rounded rather than truncated — `Int32(_:)` always rounds toward
        // zero, and outputSize was computed from the full-precision crop
        // size, so truncating just the crop dimensions here (not
        // outputSize's own derivation) would drift the two apart.
        var options = CFFmpegTranscodeOptions(
            sourceWidth: Int32(sourceSize.width.rounded()),
            sourceHeight: Int32(sourceSize.height.rounded()),
            hasCrop: hasCrop ? 1 : 0,
            cropX: Int32(cropRect.origin.x.rounded()),
            cropY: Int32(cropRect.origin.y.rounded()),
            cropWidth: Int32(cropRect.width.rounded()),
            cropHeight: Int32(cropRect.height.rounded()),
            outputWidth: Int32(outputSize.width.rounded()),
            outputHeight: Int32(outputSize.height.rounded()),
            fps: fps,
            trimStart: trim.start,
            trimEnd: trim.end,
            quality: quality,
            videoCodecName: UnsafePointer(videoCodecNameC),
            audioCodecName: audioCodecNameC.map { UnsafePointer($0) },
            audioBitrateKbps: Int32(audio?.bitrateKbps ?? 0),
            isGifTarget: isGifTarget ? 1 : 0,
            paletteColors: paletteColors,
            ditherMode: ditherModeC.map { UnsafePointer($0) },
            gifLoopCount: gifLoopCount
        )

        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let jobContext = Unmanaged.passUnretained(job).toOpaque()

        let result = errorBuffer.withUnsafeMutableBufferPointer { errorBufferPtr -> Int32 in
            withUnsafePointer(to: &options) { optionsPtr in
                cffmpeg_transcode(
                    inputPathC, outputPathC, outputFormatNameC,
                    optionsPtr,
                    ffmpegProgressCallback, jobContext,
                    ffmpegShouldCancelCallback, jobContext,
                    errorBufferPtr.baseAddress, Int32(errorBufferPtr.count)
                )
            }
        }

        if result == 1 {
            return // cancelled — ConversionJob.cancel() already handled state/cleanup.
        }
        if result != 0 {
            let message = String(cString: errorBuffer)
            throw FFmpegConversionError.transcodeFailed(code: result, message: message)
        }
    }
}

private func ffmpegProgressCallback(_ progress: Double, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<ConversionJob>.fromOpaque(context).takeUnretainedValue().reportSync(progress: progress)
}

private func ffmpegShouldCancelCallback(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<ConversionJob>.fromOpaque(context).takeUnretainedValue().isCancelledSync ? 1 : 0
}
