import Foundation

public enum AudioCodec: String, CaseIterable, Sendable, Hashable {
    // mp4 / mov
    case aac
    case alac
    case pcm
    // webm
    case opus
    case vorbis
}

public enum AudioMode: Sendable, Hashable {
    /// AAC for mp4/mov, Opus for webm (REQUIREMENTS §6).
    case auto
    case custom(codec: AudioCodec, bitrateKbps: Int)
    case stripped
}
