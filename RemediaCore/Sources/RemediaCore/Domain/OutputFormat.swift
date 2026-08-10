import Foundation

public enum OutputFormat: String, CaseIterable, Sendable, Hashable {
    case mov
    case mp4
    case gif
    case webm

    public var fileExtension: String { rawValue }

    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}
