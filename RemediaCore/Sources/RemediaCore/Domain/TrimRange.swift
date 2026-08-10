import Foundation

/// Trim in/out points, in seconds, relative to the source's own timeline.
public struct TrimRange: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public static func full(duration: TimeInterval) -> TrimRange {
        TrimRange(start: 0, end: duration)
    }
}
