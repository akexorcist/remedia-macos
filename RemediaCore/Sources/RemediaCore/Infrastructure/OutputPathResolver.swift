import Foundation

/// Computes the same-folder output path for a conversion, resolving name
/// collisions the way Finder does (REQUIREMENTS §4): `clip.mp4`, then
/// `clip (1).mp4`, `clip (2).mp4`, ...
public enum OutputPathResolver {
    public static func resolvedOutputURL(
        forSource sourceURL: URL,
        target: OutputFormat,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent

        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(target.fileExtension)

        var attempt = 1
        while fileExists(candidate) {
            candidate = directory
                .appendingPathComponent("\(baseName) (\(attempt))")
                .appendingPathExtension(target.fileExtension)
            attempt += 1
        }

        return candidate
    }
}
