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

    @Published private(set) var items: [Item] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    static let didSave = Notification.Name("CritiqueDidSave")

    init() {
        reload()
        watch()
        NotificationCenter.default.addObserver(forName: Self.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Reads every critique's feedback.json, off the main thread so a big inbox
    /// never stalls the window.
    func reload() {
        loading?.cancel()
        loading = Task {
            let fresh = await Task.detached(priority: .userInitiated) {
                Inbox.items().compactMap { dir in Inbox.load(dir).map { Item(dir: dir, record: $0) } }
            }.value
            if !Task.isCancelled { items = fresh }
        }
    }
    private var loading: Task<Void, Never>?

    func delete(_ item: Item) {
        if let project = item.record.project, item.record.before != nil {
            let repo = URL(fileURLWithPath: project.path), name = item.record.id
            Task.detached(priority: .utility) { Rewind.forget(repo, name: name) }
        }
        try? FileManager.default.trashItem(at: item.dir, resultingItemURL: nil)
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
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = Item(dir: item.dir, record: record) }
        return nil
    }

    /// Reload when a critique folder is added or removed.
    private func watch() {
        try? FileManager.default.createDirectory(at: Inbox.root, withIntermediateDirectories: true)
        let fd = open(Inbox.root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
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
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL, maxPixels: Int = 480) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
