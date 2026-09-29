import Foundation

/// Plain file-based logging for diagnosing launch issues. NSLog/os_log
/// output from this process was showing up redacted as `<private>` in the
/// unified log (Swift string interpolation isn't marked public by default),
/// making `log show` useless here -- this sidesteps that entirely.
func debugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let path = "/tmp/rainydesktop_debug.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
