import Foundation
import CFFmpeg
import CoreVideo

/// Continuous forward playback via `cffmpeg_decode_next_frame` — opens the
/// file once, unlike `FFmpegDecodePreviewSource` which reopens/reseeks on
/// every call (fine for scrubbing, far too slow at playback frame rates).
/// Not actor-isolated: safe only under the strictly sequential access this
/// class assumes (one call in flight at a time).
public final class FFmpegSequentialPlayer: @unchecked Sendable {
    private let decoderPtr: OpaquePointer

    public init?(url: URL) {
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let ptr = url.path.withCString { pathC in
            errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                cffmpeg_open_sequential_decoder(pathC, errorPtr.baseAddress, Int32(errorPtr.count))
            }
        }
        guard let ptr else { return nil }
        decoderPtr = ptr
    }

    deinit {
        cffmpeg_close_sequential_decoder(decoderPtr)
    }

    /// `nil` at end of stream or on decode failure — callers loop by
    /// calling `seek(to: 0)` and retrying.
    public func nextFrame() -> (frame: PreviewFrame, pts: TimeInterval)? {
        var dataPointer: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0
        var height: Int32 = 0
        var bytesPerRow: Int32 = 0
        var pts: Double = 0
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let status = errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
            cffmpeg_decode_next_frame(
                decoderPtr, &dataPointer, &width, &height, &bytesPerRow, &pts, errorPtr.baseAddress, Int32(errorPtr.count)
            )
        }

        guard status == 0, let dataPointer else { return nil }
        defer { cffmpeg_free_frame_data(dataPointer) }

        guard let pixelBuffer = try? BGRAPixelBufferBuilder.makePixelBuffer(
            from: dataPointer, width: Int(width), height: Int(height), sourceBytesPerRow: Int(bytesPerRow)
        ) else { return nil }

        return (PreviewFrame(pixelBuffer: pixelBuffer), pts)
    }

    public func seek(to time: TimeInterval) {
        cffmpeg_seek_sequential_decoder(decoderPtr, time)
    }
}
