import Foundation
import CFFmpeg
import CoreVideo

/// Preview for gif/webm sources, decoded in-process via the same FFmpeg
/// bridge used by `FFmpegEngine` (ARCHITECTURE §3/§5) — `AVPlayer` can't
/// play either format. Each call seeks to the nearest keyframe at or before
/// the requested time and decodes forward to the exact frame
/// (`cffmpeg_decode_frame_at` in `Sources/CFFmpeg/preview_decode.c`).
public final class FFmpegDecodePreviewSource: PreviewSource {
    public let duration: TimeInterval
    private let mediaFile: MediaFile

    public init(mediaFile: MediaFile) {
        self.mediaFile = mediaFile
        self.duration = mediaFile.duration
    }

    public func frame(at time: TimeInterval) async throws -> PreviewFrame {
        var dataPointer: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0
        var height: Int32 = 0
        var bytesPerRow: Int32 = 0
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let status = mediaFile.url.path.withCString { pathC -> Int32 in
            errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                cffmpeg_decode_frame_at(pathC, time, &dataPointer, &width, &height, &bytesPerRow, errorPtr.baseAddress, Int32(errorPtr.count))
            }
        }

        guard status == 0, let dataPointer else {
            throw PreviewError.imageGenerationFailed
        }
        defer { cffmpeg_free_frame_data(dataPointer) }

        return PreviewFrame(pixelBuffer: try BGRAPixelBufferBuilder.makePixelBuffer(
            from: dataPointer,
            width: Int(width),
            height: Int(height),
            sourceBytesPerRow: Int(bytesPerRow)
        ))
    }
}
