import Foundation

/// Wraps whichever settings apply to the chosen target format.
public enum ConversionSettings: Sendable, Equatable {
    case video(VideoSettings)
    case gif(GifSettings)

    public var trim: TrimRange {
        switch self {
        case .video(let settings): return settings.trim
        case .gif(let settings): return settings.trim
        }
    }
}
