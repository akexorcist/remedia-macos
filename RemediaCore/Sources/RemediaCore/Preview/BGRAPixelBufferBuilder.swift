import Foundation
import CoreVideo

enum BGRAPixelBufferBuilder {
    static func makePixelBuffer(
        from data: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        sourceBytesPerRow: Int
    ) throws -> CVPixelBuffer {
        var unmanagedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &unmanagedBuffer
        )
        guard status == kCVReturnSuccess, let buffer = unmanagedBuffer else {
            throw PreviewError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw PreviewError.pixelBufferCreationFailed
        }

        let destBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let destBase = base.assumingMemoryBound(to: UInt8.self)
        let rowBytesToCopy = min(sourceBytesPerRow, destBytesPerRow)
        for row in 0..<height {
            memcpy(destBase + row * destBytesPerRow, data + row * sourceBytesPerRow, rowBytesToCopy)
        }

        return buffer
    }
}
