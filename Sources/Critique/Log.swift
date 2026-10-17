import Foundation

/// Appends a line to ~/.critique/log.txt (and the system log) — handy for "why didn't it hear me?".
func log(_ message: String) {
    NSLog("Critique: %@", message)
    let url = Inbox.root.deletingLastPathComponent().appendingPathComponent("log.txt")
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
