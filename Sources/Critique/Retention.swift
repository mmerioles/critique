import Foundation

/// Keeps recordings from piling up. Screen recordings are by far the biggest thing
/// a critique leaves behind, and the agent only needs them while it's working on
/// that critique; the notes, voice and screenshots are small and stay forever.
enum Retention: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90, forever = 0

    var id: Int { rawValue }
    var name: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .forever: "Forever"
        }
    }

    static var current: Retention {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return .month }
            return Retention(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .month
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    private static let key = "retention.recordingDays"

    @MainActor private static var daily: Timer?

    /// On launch: clear the scratch folder and apply the keep-for limit, then again once a day.
    @MainActor
    static func start() {
        Task.detached(priority: .utility) {
            let freed = sweepScratch(keeping: nil, atLaunch: true)
            if freed > 0 { log("removed \(bytes(freed)) of unfinished recordings left in \(ScreenRecorder.scratch.path)") }
            await sweep()
        }
        daily = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            Task.detached(priority: .utility) { await sweep() }
        }
    }

    /// Deletes everything in the scratch folder. Between sessions it keeps the recorder's
    /// own file and anything written in the last minute, in case a session just began.
    @discardableResult
    static func sweepScratch(keeping: URL?, atLaunch: Bool = false) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: ScreenRecorder.scratch, includingPropertiesForKeys: Array(keys))) ?? []
        var freed: Int64 = 0
        for file in files {
            if file == keeping { continue }
            let values = try? file.resourceValues(forKeys: keys)
            if !atLaunch, let modified = values?.contentModificationDate, Date().timeIntervalSince(modified) < 60 { continue }
            guard (try? fm.removeItem(at: file)) != nil else { continue }
            freed += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return freed
    }

    /// Removes the video and pulled frames from critiques older than the current limit,
    /// and rewrites their feedback so the agent isn't pointed at files that are gone.
    static func sweep() async {
        guard let days = current.days else { return }
        let result = await Task.detached(priority: .utility) { strip(olderThan: days) }.value
        if result.critiques > 0 {
            log("removed recordings from \(result.critiques) critiques older than \(current.name) (\(bytes(result.bytes)))")
            await MainActor.run { NotificationCenter.default.post(name: CritiqueStore.didSave, object: nil) }
        }
    }

    /// Removes every recording, however new, and returns how much was freed.
    static func deleteAllRecordings() async -> Int64 {
        let result = await Task.detached(priority: .userInitiated) { strip(olderThan: 0) }.value
        log("deleted all recordings: \(result.critiques) critiques, \(bytes(result.bytes))")
        await MainActor.run { NotificationCenter.default.post(name: CritiqueStore.didSave, object: nil) }
        return result.bytes
    }

    private var days: Double? { self == .forever ? nil : Double(rawValue) }

    private static func strip(olderThan days: Double) -> (critiques: Int, bytes: Int64) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        var critiques = 0, freed: Int64 = 0
        for dir in Inbox.items() {
            guard var record = Inbox.load(dir), record.createdAt < cutoff else { continue }
            let video = dir.appendingPathComponent("recording.mov")
            let frames = dir.appendingPathComponent("frames")
            let hasVideo = fm.fileExists(atPath: video.path), hasFrames = fm.fileExists(atPath: frames.path)
            guard hasVideo || hasFrames || record.video != nil else { continue }
            freed += size(of: video) + size(of: frames)
            if hasVideo { try? fm.removeItem(at: video) }
            if hasFrames { try? fm.removeItem(at: frames) }
            record.video = nil // duration stays: it's still how long the critique was
            record.timeline = record.timeline?.map { moment in
                var moment = moment
                moment.frame = nil
                return moment
            }
            try? Inbox.save(record, in: dir)
            critiques += 1
        }
        return (critiques, freed)
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isRegularFile == true { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func bytes(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: n)
    }
}
