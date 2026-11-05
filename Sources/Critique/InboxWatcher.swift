import Foundation
import Synchronization

/// Wakes up when something lands in the inbox, so wait_for_feedback doesn't poll every
/// half second. A DispatchSource watches the inbox folder (and any critique folder whose
/// feedback.json hasn't finished writing); a slow poll every 5 s is the safety net.
final class InboxWatcher {
    private let wake = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "critique.mcp.watch")
    private let lock = NSLock()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    init() {
        try? FileManager.default.createDirectory(at: Inbox.root, withIntermediateDirectories: true)
        watch(Inbox.root)
    }

    deinit { cancel() }

    /// Calls `check` now and after every change, until it returns something or the deadline passes.
    /// `check` returns the folders found and whether any folder is still being written
    /// (then the fallback poll runs every second instead of every 5).
    func wait(until deadline: Date, check: () -> (found: [URL], pending: Bool)) -> [URL] {
        while true {
            let (found, pending) = check()
            if !found.isEmpty { return found }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return [] }
            _ = wake.wait(timeout: .now() + min(remaining, pending ? 1 : 5))
        }
    }

    /// Also watch a folder or file that is still being written, e.g. a new critique's
    /// folder before its feedback.json lands, or the JSON itself while it's half written.
    func watch(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard sources[url.path] == nil, sources.count < 64 else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [wake] in wake.signal() }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[url.path] = source
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
    }
}

/// Remembers which project each critique is for, keyed by folder name and feedback.json's
/// modification time, so filtering by project doesn't decode every JSON on every check.
enum InboxIndex {
    struct Entry {
        var modified: Date
        /// The project's folder, or nil for a critique that goes to any agent.
        var project: String?
    }

    private static let entries = Mutex<[String: Entry]>([:])

    /// nil while feedback.json is missing or still being written (it must decode).
    static func entry(for dir: URL) -> Entry? {
        let json = dir.appendingPathComponent("feedback.json")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: json.path))?[.modificationDate] as? Date else { return nil }
        let key = dir.lastPathComponent
        if let hit = entries.withLock({ $0[key] }), hit.modified == modified { return hit }
        guard let record = Inbox.load(dir) else { return nil }
        let entry = Entry(modified: modified, project: record.project?.path)
        entries.withLock { $0[key] = entry }
        return entry
    }
}
