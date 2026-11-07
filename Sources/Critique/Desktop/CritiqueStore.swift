import AppKit
import ImageIO

/// The critiques in ~/.critique/inbox, newest first, kept up to date for the window.
@MainActor
final class CritiqueStore: ObservableObject {
    struct Item: Identifiable {
        let dir: URL
        let record: FeedbackRecord
        var id: String { record.id }

        /// Changes since this critique can be undone (or redone).
        var canRewind: Bool { record.project != nil && record.before != nil }
        var isUndone: Bool { record.redo != nil }

        /// Screenshots you marked up (older critiques also had an opening screenshot, #1).
        var pointedShots: [FeedbackRecord.ShotRecord] {
            record.shots.filter { $0.kind != "screen" }
        }
    }

    /// The newest critiques, a page at a time: only these are held in memory.
    @Published private(set) var items: [Item] = []
    /// Every critique on disk, counted without keeping their records.
    @Published private(set) var total = 0
    @Published private(set) var totals = Totals()
    /// Search results, or nil when there's no search. Only matches are kept.
    @Published private(set) var results: [Item]?
    @Published private(set) var isSearching = false

    struct Totals { var critiques = 0, shots = 0, seconds = 0.0 }

    nonisolated static let pageSize = 5
    nonisolated static let morePage = 10
    /// A search keeps at most this many matches, newest first.
    nonisolated static let maxResults = 50

    private var shown = pageSize
    var hasMore: Bool { items.count < total }
    var remaining: Int { max(0, total - items.count) }

    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// Shots and seconds per critique folder, so stats don't re-read every file.
    private var summaries: [String: (shots: Int, seconds: Double)] = [:]
    private var query = ""

    static let didSave = Notification.Name("CritiqueDidSave")

    init() {
        reload()
        watch()
        NotificationCenter.default.addObserver(forName: Self.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() } // delivered on the main queue
        }
    }

    /// Lists the inbox, reads only the newest `shown` critiques in full, and
    /// counts the rest from a small summary, all off the main thread.
    func reload() {
        loading?.cancel()
        let shown = shown, known = summaries
        loading = Task {
            let (page, all, fresh) = await Task.detached(priority: .userInitiated) {
                let dirs = Inbox.items()
                let page = dirs.prefix(shown).compactMap { dir in Inbox.load(dir).map { Item(dir: dir, record: $0) } }
                var fresh: [String: (shots: Int, seconds: Double)] = [:]
                for dir in dirs {
                    let key = dir.lastPathComponent
                    if let hit = known[key] { fresh[key] = hit; continue }
                    if let s = Inbox.summary(dir) { fresh[key] = s }
                }
                return (page, dirs.count, fresh)
            }.value
            guard !Task.isCancelled else { return }
            items = page
            total = all
            summaries = fresh
            totals = Totals(critiques: all,
                            shots: fresh.values.reduce(0) { $0 + $1.shots },
                            seconds: fresh.values.reduce(0) { $0 + $1.seconds })
            if !query.isEmpty { search(query) }
        }
    }
    private var loading: Task<Void, Never>?

    /// Reads the next few older critiques from disk.
    func showMore() {
        shown = items.count + Self.morePage
        reload()
    }

    /// Finds critiques by words, project, phone or time ("yesterday", "oct 30",
    /// "2:06am"). Scans the files in the background; only matches stay in memory.
    func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        guard !query.isEmpty else { results = nil; isSearching = false; return }
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))   // wait out typing
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                var found: [Item] = []
                for dir in Inbox.items() {
                    if Task.isCancelled || found.count >= Self.maxResults { break }
                    guard let record = Inbox.load(dir), Self.matches(record, tokens) else { continue }
                    found.append(Item(dir: dir, record: record))
                }
                return found
            }.value
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
    private var searchTask: Task<Void, Never>?

    /// Every word must appear in what was said, the project, the phone or the
    /// critique's date and time, written the ways people type them.
    nonisolated static func matches(_ record: FeedbackRecord, _ tokens: [String]) -> Bool {
        let d = record.createdAt, cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        func fmt(_ p: String) -> String { f.dateFormat = p; return f.string(from: d).lowercased() }
        var words = [record.notes, record.project?.name ?? "", record.device?.model ?? "", record.device?.app ?? "",
                     fmt("EEEE"), fmt("MMM d"), fmt("MMMM d"), fmt("M/d"), fmt("h:mma"), fmt("h:mm a"), fmt("ha"), fmt("yyyy")]
        if cal.isDateInToday(d) { words.append("today") }
        if cal.isDateInYesterday(d) { words.append("yesterday") }
        let hay = words.joined(separator: " ").lowercased()
        return tokens.allSatisfy { hay.contains($0) }
    }

    private func replace(_ item: Item) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        if let i = results?.firstIndex(where: { $0.id == item.id }) { results?[i] = item }
    }

    func delete(_ item: Item) {
        if let project = item.record.project, item.record.before != nil {
            let repo = URL(fileURLWithPath: project.path), name = item.record.id
            Task.detached(priority: .utility) { Rewind.forget(repo, name: name) }
        }
        try? FileManager.default.trashItem(at: item.dir, resultingItemURL: nil)
        results?.removeAll { $0.id == item.id }
        reload()
    }

    /// Puts the project back to how it was before this critique. Returns an error to show, or nil.
    func undo(_ item: Item) async -> String? {
        guard let project = item.record.project, let before = item.record.before else { return "No snapshot" }
        return await rewind(item, repo: URL(fileURLWithPath: project.path), to: before, undoing: true)
    }

    /// Brings back the changes an undo removed.
    func redo(_ item: Item) async -> String? {
        guard let project = item.record.project, let redo = item.record.redo else { return nil }
        return await rewind(item, repo: URL(fileURLWithPath: project.path), to: redo, undoing: false)
    }

    private func rewind(_ item: Item, repo: URL, to point: Rewind.Point, undoing: Bool) async -> String? {
        let name = item.record.id + "-redo"
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Rewind.restore(repo, to: point, name: name) }
        }.value
        var record = item.record
        switch result {
        case .success(let now): record.redo = undoing ? now : nil
        case .failure(let error): return error.localizedDescription
        }
        try? Inbox.save(record, in: item.dir)
        replace(Item(dir: item.dir, record: record))
        return nil
    }

    /// Reload when a critique folder is added or removed.
    private func watch() {
        try? FileManager.default.createDirectory(at: Inbox.root, withIntermediateDirectories: true)
        let fd = open(Inbox.root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { // the source runs on the main queue
                guard let self else { return }
                // Files are still being written right after the folder appears.
                self.pending?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.reload() }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

/// Small, cached thumbnails so the list stays fast with full-resolution screenshots.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL, maxPixels: Int = 480) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        // Decode off the main actor, but hand back the CGImage: NSImage is only
        // Sendable from the macOS 26 SDK on, so it's made here instead.
        let cg: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
