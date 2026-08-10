import Foundation

/// Resolution/scale override, always aspect-ratio preserving (REQUIREMENTS §6/§7).
public enum ResolutionOverride: Sendable, Hashable {
    case original
    /// Scale factor relative to the source resolution (e.g. 1.0, 0.75, 0.5, 0.25).
    case scale(Double)
    /// Custom target width in pixels; height is computed from the source aspect ratio.
    case customWidth(Int)
}
