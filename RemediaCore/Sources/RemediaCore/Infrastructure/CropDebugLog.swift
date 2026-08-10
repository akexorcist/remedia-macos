import Foundation

/// Temporary diagnostic logging for the mov/mp4 crop-position/stretch bug
/// report — appends to a fixed path so it can be read back after a real
/// repro without needing to attach a debugger or stream `os_log` live.
/// Remove once the bug is confirmed fixed.
enum CropDebugLog {
    static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("remedia-crop-debug.log").path

    static func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        // O_NOFOLLOW: this path lives in a shared temp directory, so refuse
        // to append through a symlink another local process may have
        // swapped in; 0o600 keeps the log itself from being world-readable.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(data)
    }
}
