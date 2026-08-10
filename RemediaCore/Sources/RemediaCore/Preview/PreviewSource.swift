import Foundation
import CoreVideo

/// `CVPixelBuffer` (a Core Foundation type) isn't `Sendable`, but is safe to
/// hand across concurrency domains here since preview frames are read-only
/// once produced and never mutated by more than one owner.
public struct PreviewFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer

    public init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

/// Feeds the preview player (scrubber + crop overlay) regardless of whether
/// the source format is natively playable (ARCHITECTURE §3).
public protocol PreviewSource: Sendable {
    var duration: TimeInterval { get }
    func frame(at time: TimeInterval) async throws -> PreviewFrame
}
