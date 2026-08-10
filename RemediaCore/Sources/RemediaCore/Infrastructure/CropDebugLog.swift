import Foundation

/// Temporary diagnostic logging for the mov/mp4 crop-position/stretch bug
/// report — appends to a fixed path so it can be read back after a real
/// repro without needing to attach a debugger or stream `os_log` live.
/// Remove once the bug is confirmed fixed.
public enum CropDebugLog {
    public static let path = "/tmp/mediaconverter-crop-debug.log"

    public static func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
