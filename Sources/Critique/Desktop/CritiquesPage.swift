import AppKit
import SwiftUI

/// "Welcome back" + a banner + your critiques grouped by day, each one showing
/// what you said and the screenshots you pointed at while saying it.
struct CritiquesPage: View {
    @ObservedObject var store: CritiqueStore
    let handoff: AgentHandoff
    @State private var search = ""
    @State private var searching = false
    @State private var preview: Preview?

    struct Preview: Identifiable {
        let url: URL
        let title: String
        var id: URL { url }
    }

    private var filtered: [CritiqueStore.Item] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { $0.record.notes.localizedCaseInsensitiveContains(query) }
    }

    private var days: [(title: String, items: [CritiqueStore.Item])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.record.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "TODAY" }
            else if calendar.isDateInYesterday(day) { title = "YESTERDAY" }
            else { title = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased() }
            return (title, groups[day]!.sorted { $0.record.createdAt > $1.record.createdAt })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Welcome back\(Self.firstName.map { ", \($0)" } ?? "")")
                    .font(.system(size: 26, weight: .medium))
                    .padding(.top, 8)

                HStack(alignment: .top, spacing: 20) {
                    Banner()
                    Stats(items: store.items)
                        .frame(width: 250)
                }

                if store.items.isEmpty {
                    EmptyState()
                } else {
                    ForEach(days, id: \.title) { day in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(day.title)
                                    .font(.system(size: 12, weight: .medium)).kerning(1.2)
                                    .foregroundStyle(Theme.secondary)
                                Spacer()
                                if day.title == days.first?.title { searchControl }
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { Divider().overlay(Theme.border) }
                                    CritiqueRow(item: item, handoff: handoff, store: store) { url, title in
                                        preview = Preview(url: url, title: title)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 32)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $preview) { PreviewSheet(preview: $0) }
    }

    @ViewBuilder private var searchControl: some View {
        if searching {
            TextField("Search critiques", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onExitCommand { searching = false; search = "" }
        } else {
            Button { searching = true } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Search critiques")
        }
    }

    private static var firstName: String? {
        NSFullUserName().split(separator: " ").first.map { $0.capitalized }
    }
}

private struct Banner: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.banner)
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    (Text("Critique anything ") + Text("on your screen").italic())
                        .font(.system(size: 28, weight: .regular, design: .serif))
                    Text("Double-tap right ⌥, then talk and point. Your agent gets the rest.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                LogoImage().frame(width: 96, height: 96).opacity(0.95)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .frame(height: 170)
    }
}

private struct Stats: View {
    let items: [CritiqueStore.Item]

    var body: some View {
        let shots = items.reduce(0) { $0 + $1.record.shots.count }
        let seconds = items.reduce(0.0) { $0 + ($1.record.duration ?? 0) }
        VStack(alignment: .leading, spacing: 10) {
            stat("\(items.count)", "critiques")
            stat("\(shots)", "screenshots")
            stat(seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m", "recorded")
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.sidebar))
        .frame(height: 170)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 26, design: .serif))
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(Theme.tertiary)
            Text("No critiques yet").font(.system(size: 15, weight: .medium))
            Text("Double-tap right ⌥ anywhere, talk, and point at what you mean.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

/// One critique: time on the left; your words (with red #n markers) and the
/// screenshots they point to on the right. Actions appear on hover.
struct CritiqueRow: View {
    let item: CritiqueStore.Item
    let handoff: AgentHandoff
    let store: CritiqueStore
    let open: (URL, String) -> Void
    @State private var hovering = false
    @State private var sent = false

    private var record: FeedbackRecord { item.record }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.time(record.createdAt)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Text(details).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                words
                if !item.pointedShots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(item.pointedShots, id: \.number) { shot in
                                ShotThumbnail(shot: shot, dir: item.dir) {
                                    open(item.dir.appendingPathComponent(shot.file), Self.caption(shot))
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Actions get their own column so they never cover your words.
            actions
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(hovering ? Theme.hover : Theme.panel)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Your words with [#n] markers drawn as small red numbers.
    private var words: some View {
        let notes = record.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = Text("")
        var said = false
        var rest = Substring(notes)
        while let range = rest.range(of: #"\[#\d+\]"#, options: .regularExpression) {
            let before = rest[..<range.lowerBound]
            if !before.trimmingCharacters(in: .whitespaces).isEmpty { said = true }
            text = text + Text(before)
            let number = rest[range].dropFirst(2).dropLast()
            // A small red superscript, like a footnote pointing to screenshot #n.
            text = text + Text("\(number)").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.red).baselineOffset(6)
            rest = rest[range.upperBound...]
        }
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { said = true }
        text = text + Text(rest)
        return Group {
            if said {
                text.font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
            } else {
                Text("Nothing said — just pointing.").font(.system(size: 14)).italic().foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 2) {
            action(sent ? "checkmark" : "paperplane", sent ? "Sent" : "Send to Claude Code") {
                let path = item.dir.appendingPathComponent("feedback.md").path
                copyMarkdown()
                handoff.deliver(line: "Implement my UX feedback from Critique: \(path). Read it and look at the screenshots first.") { app in
                    sent = app != nil
                }
            }
            action("doc.on.doc", "Copy for your agent") { copyMarkdown() }
            if let video = record.video {
                action("play.rectangle", "Play recording") { NSWorkspace.shared.open(item.dir.appendingPathComponent(video)) }
            }
            action("folder", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.dir]) }
            action("trash", "Move to Trash") { store.delete(item) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    private func action(_ icon: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .help(help)
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.markdown(in: item.dir), forType: .string)
    }

    private var details: String {
        var parts: [String] = []
        if let d = record.duration { parts.append(FeedbackRecord.clock(d)) }
        let n = record.shots.count
        parts.append("\(n) shot\(n == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    static func caption(_ shot: FeedbackRecord.ShotRecord) -> String {
        var text = "#\(shot.number) \(FeedbackRecord.label(shot.kind))"
        if let element = shot.element { text += " \(element)" }
        if let at = shot.at { text += " · \(FeedbackRecord.clock(at))" }
        return text
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: date)
    }
}

/// A screenshot with its red number, tied to the [#n] in the words above.
private struct ShotThumbnail: View {
    let shot: FeedbackRecord.ShotRecord
    let dir: URL
    let open: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.sidebar
                    }
                }
                .frame(width: 148, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering ? Theme.red.opacity(0.6) : Theme.border))

                Text("\(shot.number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.red))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .help(CritiqueRow.caption(shot))
        .onHover { hovering = $0 }
        .task {
            image = await Thumbnails.image(dir.appendingPathComponent(shot.file))
        }
    }
}

private struct PreviewSheet: View {
    let preview: CritiquesPage.Preview
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(preview.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(preview.url) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(width: 900, height: 620)
        .task { image = await Thumbnails.image(preview.url, maxPixels: 2400) }
    }
}
