import AppKit
import SwiftUI

/// Where critiques are saved, how much space they take, and a way to clear out old ones.
struct StoragePage: View {
    @ObservedObject var store: CritiqueStore
    @State private var usage: StorageUsage?
    @State private var age: Age = .month
    @State private var scope: Scope = .everything
    @State private var confirming = false

    enum Age: String, CaseIterable, Identifiable {
        case week = "Older than 1 week"
        case month = "Older than 1 month"
        case quarter = "Older than 3 months"
        case all = "All critiques"
        var id: String { rawValue }
        var days: Double? {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            case .all: nil
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case everything = "Whole critiques"
        case media = "Just videos and audio"
        var id: String { rawValue }
    }

    var body: some View {
        PageScaffold(title: "Storage", subtitle: "Your critiques are saved on this Mac. Nothing is uploaded.") {
            location
            if let usage {
                disk(usage)
                breakdown(usage)
                cleanup(usage)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: store.items.map(\.id)) { usage = await StorageUsage.measure() }
    }

    // MARK: Sections

    private var location: some View {
        RowList {
            HStack(spacing: 14) {
                Image(systemName: "folder").foregroundStyle(Theme.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved in").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text(Inbox.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(Inbox.root) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func disk(_ usage: StorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Disk")
            HStack(alignment: .firstTextBaseline) {
                Text(bytes(usage.diskFree)).font(.system(size: 30, weight: .regular, design: .serif))
                Text("free of \(bytes(usage.diskTotal))").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                Spacer()
                Text("Critique uses \(bytes(usage.total))").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { geo in
                let total = max(Double(usage.diskTotal), 1)
                let used = Double(usage.diskTotal - usage.diskFree)
                let mine = max(Double(usage.total) / total * geo.size.width, usage.total > 0 ? 3 : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.selected)
                    Capsule().fill(Theme.tertiary).frame(width: used / total * geo.size.width)
                    Capsule().fill(Theme.red).frame(width: mine)
                }
            }
            .frame(height: 10)
            HStack(spacing: 16) {
                legend(Theme.red, "Critique")
                legend(Theme.tertiary, "Other files")
                legend(Theme.selected, "Free")
            }
        }
    }

    private func breakdown(_ usage: StorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            section("What's taking space")
            RowList {
                kindRow("film", "Screen recordings", usage.videos)
                Divider().overlay(Theme.border)
                kindRow("waveform", "Voice audio", usage.audio)
                Divider().overlay(Theme.border)
                kindRow("photo", "Screenshots and frames", usage.images)
                Divider().overlay(Theme.border)
                kindRow("doc.text", "Notes and transcripts", usage.notes)
            }
        }
    }

    private func cleanup(_ usage: StorageUsage) -> some View {
        let picked = usage.critiques.filter { matches($0) }
        let saving = picked.reduce(Int64(0)) { $0 + (scope == .media ? $1.media : $1.total) }
        return VStack(alignment: .leading, spacing: 12) {
            section("Clean up")
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Picker("", selection: $age) {
                        ForEach(Age.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frees up \(bytes(saving))").font(.system(size: 18, weight: .medium))
                        Text(summary(count: picked.count))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("Move to Trash") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.red)
                        .disabled(saving == 0)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .confirmationDialog("Move \(picked.count == 1 ? "1 critique" : "\(picked.count) critiques") to the Trash?",
                                isPresented: $confirming) {
                Button("Move to Trash", role: .destructive) { clean(picked) }
            } message: {
                Text(scope == .media
                     ? "Their videos and audio go to the Trash. Notes and screenshots stay. Empty the Trash to free \(bytes(saving))."
                     : "You can get them back from the Trash. Empty the Trash to free \(bytes(saving)).")
            }
        }
    }

    // MARK: Helpers

    private func matches(_ critique: StorageUsage.Critique) -> Bool {
        guard let days = age.days else { return true }
        return critique.date < Date().addingTimeInterval(-days * 86_400)
    }

    private func summary(count: Int) -> String {
        if count == 0 { return "No critiques match." }
        let what = scope == .media ? "Removes videos and audio from" : "Removes"
        return "\(what) \(count == 1 ? "1 critique" : "\(count) critiques")."
    }

    private func clean(_ picked: [StorageUsage.Critique]) {
        let fm = FileManager.default
        for critique in picked {
            if scope == .media {
                for name in ["recording.mov", "voice.m4a"] {
                    let file = critique.dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: file.path) { try? fm.trashItem(at: file, resultingItemURL: nil) }
                }
            } else {
                try? fm.trashItem(at: critique.dir, resultingItemURL: nil)
            }
        }
        store.reload()
        Task { usage = await StorageUsage.measure() }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 12, weight: .medium)).kerning(1.2).foregroundStyle(Theme.secondary)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }

    private func kindRow(_ icon: String, _ name: String, _ size: Int64) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(Theme.secondary).frame(width: 20)
            Text(name).font(.system(size: 14))
            Spacer()
            Text(bytes(size)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func bytes(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: n)
    }
}

/// Sizes of everything in the inbox, by kind and by critique, plus free disk space.
struct StorageUsage: Sendable {
    struct Critique: Sendable {
        let dir: URL
        let date: Date
        var total: Int64 = 0
        var media: Int64 = 0
    }

    var critiques: [Critique] = []
    var videos: Int64 = 0
    var audio: Int64 = 0
    var images: Int64 = 0
    var notes: Int64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var total: Int64 { videos + audio + images + notes }

    static func measure() async -> StorageUsage {
        await Task.detached(priority: .utility) { scan() }.value
    }

    private static func scan() -> StorageUsage {
        var usage = StorageUsage()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        for dir in Inbox.items() {
            let date = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            var critique = Critique(dir: dir, date: date)
            let files = fm.enumerator(at: dir, includingPropertiesForKeys: keys)
            while let file = files?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                critique.total += size
                switch file.pathExtension.lowercased() {
                case "mov", "mp4":
                    usage.videos += size
                    critique.media += size
                case "m4a", "wav", "caf":
                    usage.audio += size
                    critique.media += size
                case "png", "jpg", "jpeg":
                    usage.images += size
                default:
                    usage.notes += size
                }
            }
            usage.critiques.append(critique)
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            usage.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            usage.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
        return usage
    }
}
