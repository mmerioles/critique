import Foundation
import Testing
@testable import Critique

struct InboxTests {
    @Test func newIDsSortInTimeOrder() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let ids = [0, 1, 59, 60, 3600, 86_400, 31 * 86_400, 400 * 86_400].map { Inbox.newID(for: base.addingTimeInterval(Double($0))) }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, "\(id)")
        }
    }

    @Test func newIDIsLocalTime() {
        var parts = DateComponents()
        parts.year = 2025; parts.month = 10; parts.day = 30; parts.hour = 2; parts.minute = 6; parts.second = 7
        let date = Calendar.current.date(from: parts)!
        #expect(Inbox.newID(for: date) == "2025-10-30_02-06-07")
    }

    @Test func itemsAreNewestFirstAndOnlyRealFeedback() throws {
        try withTemporaryInbox { root in
            #expect(Inbox.items().isEmpty)
            let names = ["2026-10-30_02-06-00", "2026-11-01_10-00-00", "2026-11-01_10-00-00-2", "2025-12-31_23-59-59"]
            for name in names {
                let dir = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try "{}".write(to: dir.appendingPathComponent("feedback.json"), atomically: true, encoding: .utf8)
            }
            // Folders without feedback.json and loose files don't count.
            try FileManager.default.createDirectory(at: root.appendingPathComponent("2026-11-02_00-00-00"), withIntermediateDirectories: true)
            try "x".write(to: root.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
            #expect(Inbox.items().map(\.lastPathComponent) ==
                    ["2026-11-01_10-00-00-2", "2026-11-01_10-00-00", "2026-10-30_02-06-00", "2025-12-31_23-59-59"])
        }
    }

    @Test func itemsWhenTheInboxDoesNotExist() throws {
        try withTemporaryInbox { root in
            try FileManager.default.removeItem(at: root)
            #expect(Inbox.items().isEmpty)
        }
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withTemporaryInbox { root in
            let record = sampleRecord()
            let dir = root.appendingPathComponent(record.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Inbox.save(record, in: dir)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("feedback.md").path))

            let loaded = try #require(Inbox.load(dir))
            #expect(loaded.id == record.id)
            #expect(loaded.createdAt == record.createdAt)
            #expect(loaded.notes == record.notes)
            #expect(loaded.video == "recording.mov")
            #expect(loaded.duration == 12.5)
            #expect(loaded.audio == "voice.m4a")
            #expect(loaded.engine == "whisper")
            #expect(loaded.liveNotes == record.liveNotes)
            #expect(loaded.shots.count == 1)
            #expect(loaded.shots[0].region == [10, 20, 300, 40])
            #expect(loaded.shots[0].pointer == [15, 25])
            #expect(loaded.shots[0].said == "this button is way too big")
            #expect(loaded.shots[0].inside == ["button “Sign up”", "link “Cancel”"])
            #expect(loaded.timeline?.count == 4)
            #expect(loaded.timeline?[2].frame == "frames/0-01.8.jpg")
            #expect(loaded.timeline?[3].shot == 1)
            #expect(loaded.project?.name == "mmerioles/critique")
            #expect(loaded.project?.branch == "main")
            #expect(loaded.before == record.before)
            #expect(loaded.redo == nil)
            #expect(loaded.device?.model == "Pixel 8")
            #expect(loaded.device?.reinstalls == true)

            // Saving what was loaded writes the very same bytes.
            let again = root.appendingPathComponent("again")
            try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
            try Inbox.save(loaded, in: again)
            #expect(try Data(contentsOf: again.appendingPathComponent("feedback.json")) == Data(contentsOf: dir.appendingPathComponent("feedback.json")))

            #expect(Inbox.summary(dir)?.shots == 1)
            #expect(Inbox.summary(dir)?.seconds == 12.5)
        }
    }

    @Test func loadIsNilForMissingOrBrokenFiles() throws {
        try withTemporaryInbox { root in
            let dir = root.appendingPathComponent("nothing")
            #expect(Inbox.load(dir) == nil)
            #expect(Inbox.summary(dir) == nil)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "not json".write(to: dir.appendingPathComponent("feedback.json"), atomically: true, encoding: .utf8)
            #expect(Inbox.load(dir) == nil)
        }
    }

    @Test func seen() throws {
        try withTemporaryInbox { root in
            let dir = root.appendingPathComponent("x")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #expect(!Inbox.isSeen(dir))
            Inbox.markSeen(dir)
            #expect(Inbox.isSeen(dir))
        }
    }

    @Test func rootFollowsTheOverride() {
        withTemporaryInbox { root in
            #expect(Inbox.root == root)
        }
        #expect(Inbox.root.lastPathComponent == "inbox")
    }
}

struct FeedbackRecordTests {
    @Test func clock() {
        #expect(FeedbackRecord.clock(0) == "0:00")
        #expect(FeedbackRecord.clock(7) == "0:07")
        #expect(FeedbackRecord.clock(59.4) == "0:59")
        #expect(FeedbackRecord.clock(59.5) == "1:00")
        #expect(FeedbackRecord.clock(65) == "1:05")
        #expect(FeedbackRecord.clock(3600) == "60:00")
        #expect(FeedbackRecord.clock(0, tenths: true) == "0:00.0")
        #expect(FeedbackRecord.clock(4.2, tenths: true) == "0:04.2")
        #expect(FeedbackRecord.clock(4.25, tenths: true) == "0:04.3")
        #expect(FeedbackRecord.clock(59.96, tenths: true) == "1:00.0")
        #expect(FeedbackRecord.clock(61.96, tenths: true) == "1:02.0")
        #expect(FeedbackRecord.clock(600, tenths: true) == "10:00.0")
    }

    @Test func label() {
        #expect(FeedbackRecord.label("drawing") == "Drew on")
        #expect(FeedbackRecord.label("pointer") == "Pointing at")
        #expect(FeedbackRecord.label("click") == "Clicked")
        #expect(FeedbackRecord.label("tap") == "Tapped")
        #expect(FeedbackRecord.label("screen") == "Screen")
        #expect(FeedbackRecord.label("whatever") == "Screen")
    }

    @Test func markdownHasEverySection() {
        let record = sampleRecord()
        let dir = URL(fileURLWithPath: "/tmp/inbox/\(record.id)")
        let md = record.markdown(in: dir)
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0] == "# UX feedback · \(FeedbackRecord.displayDate.string(from: record.createdAt))")
        #expect(lines.contains("## Project"))
        #expect(lines.contains("This critique is for **mmerioles/critique** at `/Users/me/repos/critique` (branch `main`). Make the changes there."))
        #expect(lines.contains("## Phone"))
        #expect(md.contains("Recorded on their Android phone (**Pixel 8**, adb serial `ABCD1234`) while testing `bordgame.app` (`.MainActivity`)."))
        #expect(md.contains("Critique rebuilds the app with Gradle (`installDebug`)"))
        #expect(lines.contains("## What they said"))
        #expect(lines.contains("> The header looks fine but [#1] this button is way too big."))
        #expect(md.contains("or listen to their voice: `/tmp/inbox/\(record.id)/voice.m4a`"))
        #expect(lines.contains("### Also heard live (a second transcript — compare if something seems off)"))
        #expect(lines.contains("> The header looks fine but this button is way to big."))
        #expect(lines.contains("## Timeline"))
        #expect(lines.contains("- **0:00.0** said “The header looks fine but”"))
        #expect(lines.contains("- **0:00.9** clicked menu button “File”"))
        #expect(lines.contains("- **0:01.6** hovered menu item “Export…” · frame: `/tmp/inbox/\(record.id)/frames/0-01.8.jpg`"))
        #expect(lines.contains("- **0:04.2** #1 drew around button “Sign up”, link “Cancel”"))
        #expect(lines.contains("## Screen recording"))
        #expect(md.contains("`/tmp/inbox/\(record.id)/recording.mov` — 0:13 of their screen with their voice"))
        #expect(lines.contains("## Screenshots"))
        #expect(lines.contains("- **#1 Drew on** button “Sign up” · Safari — “Home”"))
        #expect(lines.contains("  - Inside the drawing: button “Sign up”, link “Cancel”"))
        #expect(lines.contains("  - Image: `/tmp/inbox/\(record.id)/1-drawing.png`"))
        #expect(lines.contains("  - Box: 300×40 px at (10, 20)"))
        #expect(lines.contains("  - Cursor at: (15, 25) px"))
        // Sections come in reading order.
        let order = ["## Project", "## Phone", "## What they said", "## Timeline", "## Screen recording", "## Screenshots"]
            .compactMap { lines.firstIndex(of: $0) }
        #expect(order == order.sorted() && order.count == 6)
    }

    @Test func markdownForABareCritique() {
        let record = FeedbackRecord(id: "2026-11-04_09-00-00", createdAt: Date(), notes: "  [#1] ", shots: [
            FeedbackRecord.ShotRecord(number: 1, kind: "screen", file: "1-screen.png", app: nil, window: nil),
        ])
        let md = record.markdown(in: URL(fileURLWithPath: "/tmp/x"))
        #expect(md.contains("_(Nothing was said — follow the timeline and screenshots.)_"))
        #expect(!md.contains("Speech-to-text can mishear"))
        #expect(!md.contains("## Project"))
        #expect(!md.contains("## Phone"))
        #expect(!md.contains("## Timeline"))
        #expect(!md.contains("## Screen recording"))
        #expect(!md.contains("Also heard live"))
        #expect(md.contains("- **#1 Screen** · Unknown app\n  - Image: `/tmp/x/1-screen.png`\n"))
    }

    @Test func markdownQuotesEveryLineSaid() {
        var record = sampleRecord()
        record.notes = "first line\n\nthird line"
        let md = record.markdown(in: URL(fileURLWithPath: "/tmp/x"))
        #expect(md.contains("> first line\n> \n> third line\n"))
    }
}
