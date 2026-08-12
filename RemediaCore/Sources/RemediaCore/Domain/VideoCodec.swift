import Foundation

/// mp4/mov only — webm and gif each have exactly one codec they're encoded
/// with, so there's nothing to choose there.
public enum VideoCodec: String, CaseIterable, Sendable, Hashable {
    case auto
    case h264
    case hevc
}
