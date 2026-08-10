import Foundation

public protocol ConversionEngine: Sendable {
    /// Starts converting `source` to `target` with `settings`, writing to `outputURL`.
    /// Returns immediately with a running `ConversionJob`; conversion happens
    /// asynchronously and reports progress/completion through it.
    func convert(
        _ source: MediaFile,
        to target: OutputFormat,
        settings: ConversionSettings,
        outputURL: URL
    ) -> ConversionJob
}
