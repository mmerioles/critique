import Foundation

/// A long-running command whose output arrives line by line on the main thread
/// (adb logcat, getevent, scrcpy).
/// Unchecked: `buffer` is only touched by the pipe's readability handler, one call at a time.
final class LineProcess: @unchecked Sendable {
    private let process = Process()
    private var buffer = Data()
    private let onLine: @MainActor @Sendable (String) -> Void
    var onExit: (@MainActor @Sendable (Int32) -> Void)?

    init(_ executable: String, _ args: [String], onLine: @escaping @MainActor @Sendable (String) -> Void) {
        self.onLine = onLine
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ADB.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.take(data)
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor [weak self] in self?.onExit?(status) }
        }
    }

    private func take(_ data: Data) {
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            buffer.removeSubrange(buffer.startIndex...end)
            lines.append(line)
        }
        guard !lines.isEmpty else { return }
        let onLine = onLine
        Task { @MainActor [lines] in lines.forEach(onLine) }
    }

    func start() throws { try process.run() }
    var isRunning: Bool { process.isRunning }

    /// Ctrl-C: lets scrcpy finish writing its recording.
    func interrupt() { if process.isRunning { process.interrupt() } }
    func stop() { if process.isRunning { process.terminate() } }

    /// Waits (off the main thread) for it to exit, up to `timeout`.
    func waitForExit(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate() }
    }
}
