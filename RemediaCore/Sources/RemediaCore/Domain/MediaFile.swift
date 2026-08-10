import Foundation
import CoreGraphics

public struct MediaFile: Sendable, Equatable {
    public let url: URL
    public let format: OutputFormat
    public let duration: TimeInterval
    public let resolution: CGSize
    public let frameRate: Double
    public let hasAudio: Bool

    public init(
        url: URL,
        format: OutputFormat,
        duration: TimeInterval,
        resolution: CGSize,
        frameRate: Double,
        hasAudio: Bool
    ) {
        self.url = url
        self.format = format
        self.duration = duration
        self.resolution = resolution
        self.frameRate = frameRate
        self.hasAudio = hasAudio
    }
}
