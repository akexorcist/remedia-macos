import Foundation

public enum PaletteSize: Sendable, Hashable {
    case auto
    case colors(Int)
}

public enum DitherMethod: Sendable, Hashable {
    case auto
    case none
    case bayer
    case floydSteinberg
}

public enum LoopBehavior: Sendable, Hashable {
    case forever
    case times(Int)
    case once
}
