import AppKit
import ImageIO

/// The critiques in ~/.critique/inbox, newest first, kept up to date for the window.
@MainActor
final class CritiqueStore: ObservableObject {
    struct Item: Identifiable {
        let dir: URL
        let record: FeedbackRecord
        var id: String { record.id }

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

    func reload() {
        items = Inbox.items().compactMap { dir in Inbox.load(dir).map { Item(dir: dir, record: $0) } }
    }

    func delete(_ item: Item) {
        try? FileManager.default.trashItem(at: item.dir, resultingItemURL: nil)
        reload()
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
