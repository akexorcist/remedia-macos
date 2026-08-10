import Foundation

public enum FrameRateOverride: Sendable, Hashable {
    case original
    /// Target frames per second. Downsampling drops frames; upsampling duplicates
    /// frames (no motion interpolation) per REQUIREMENTS §6.
    case fps(Double)
}
