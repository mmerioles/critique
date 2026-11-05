import Foundation
import Testing
@testable import Critique

struct FeedbackWriterTests {
    /// Time zero, so offsets come back exactly as given.
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func shotRecord(_ number: Int, _ kind: String, at seconds: Double, element: String? = nil,
                    inside: [String]? = nil) -> FeedbackRecord.ShotRecord {
        var record = FeedbackRecord.ShotRecord(number: number, kind: kind, file: "\(number)-\(kind).png", app: "Safari", window: nil)
        record.at = seconds
        record.element = element
        record.inside = inside
        return record
    }

    // MARK: Timeline

    @Test func wordsAreGroupedIntoPhrasesAtPausesAndSentenceEnds() {
        let words = [("the", 0.0), ("header", 0.4), ("looks", 0.8), ("fine.", 1.2),
                     ("but", 1.6), ("this", 2.0),
                     ("button", 5.0), ("is", 5.3), ("too", 5.6), ("big", 5.9)]
            .map { SpokenWord(text: $0.0, time: at($0.1)) }
        let input = FeedbackWriter.Input(notes: "", shots: [], words: words, clockStart: t0)
        let moments = FeedbackWriter.timeline(input, shots: [], video: nil, dir: URL(fileURLWithPath: "/tmp/none"))
        #expect(moments.map(\.kind) == ["said", "said", "said"])
        #expect(moments.map(\.text) == ["the header looks fine.", "but this", "button is too big"])
        #expect(moments.map(\.at) == [0.0, 1.6, 5.0])
        #expect(moments.allSatisfy { $0.frame == nil && $0.shot == nil })
    }

    @Test func longPhrasesBreakAtThirtyWords() {
        let words = (0..<45).map { SpokenWord(text: "w\($0)", time: at(Double($0) * 0.1)) }
        let input = FeedbackWriter.Input(notes: "", shots: [], words: words, clockStart: t0)
        let moments = FeedbackWriter.timeline(input, shots: [], video: nil, dir: URL(fileURLWithPath: "/tmp/none"))
        #expect(moments.count == 2)
        #expect(moments[0].text.split(separator: " ").count == 30)
        #expect(moments[1].text.hasPrefix("w30 "))
        #expect(moments[1].text.split(separator: " ").count == 15)
    }

    @Test func wordsBeforeTheClockStartedLandAtZero() {
        let words = [SpokenWord(text: "early", time: at(-3)), SpokenWord(text: "words", time: at(-2.5))]
        let input = FeedbackWriter.Input(notes: "", shots: [], words: words, clockStart: t0)
        let moments = FeedbackWriter.timeline(input, shots: [], video: nil, dir: URL(fileURLWithPath: "/tmp/none"))
        #expect(moments.map(\.at) == [0])
        #expect(moments[0].text == "early words")
    }

    @Test func interactionsAndShotsAreMergedInTimeOrder() {
        let words = [("the", 0.0), ("header", 0.4)].map { SpokenWord(text: $0.0, time: at($0.1)) }
        let interactions = [
            Interaction(kind: .hover, label: "menu button “File”", time: at(0.9)),
            Interaction(kind: .click, label: "button “Sign up”", time: at(4.2)),  // has its own shot (#3): dropped
            Interaction(kind: .click, label: "link “Cancel”", time: at(7.0)),     // no shot: kept
            Interaction(kind: .swipe, label: "up", time: at(8.0)),
        ]
        let shots = [
            shotRecord(1, "screen", at: 0),                                                     // the opening screen is skipped
            shotRecord(2, "drawing", at: 4.0, inside: ["button “Sign up”", "link “Cancel”"]),
            shotRecord(3, "click", at: 4.3, element: "button “Sign up”"),
            shotRecord(4, "pointer", at: 6.0),
            shotRecord(5, "drawing", at: 6.5),
            shotRecord(6, "tap", at: 9.0),
            shotRecord(7, "click", at: 9.5),
            shotRecord(8, "screen", at: 10.0),
            shotRecord(9, "pointer", at: 2.0, element: "field “Email”"),
        ]
        let input = FeedbackWriter.Input(notes: "", shots: [], words: words, interactions: interactions, clockStart: t0)
        let moments = FeedbackWriter.timeline(input, shots: shots, video: nil, dir: URL(fileURLWithPath: "/tmp/none"))
        let expected: [(Double, String, String, Int?)] = [
            (0.0, "said", "the header", nil),
            (0.9, "hover", "menu button “File”", nil),
            (2.0, "shot", "#9 pointing at field “Email”", 9),
            (4.0, "shot", "#2 drew around button “Sign up”, link “Cancel”", 2),
            (4.3, "shot", "#3 clicked button “Sign up”", 3),
            (6.0, "shot", "#4 pointing here", 4),
            (6.5, "shot", "#5 drew on the screen", 5),
            (7.0, "click", "link “Cancel”", nil),
            (8.0, "swipe", "up", nil),
            (9.0, "shot", "#6 tapped here", 6),
            (9.5, "shot", "#7 clicked here", 7),
            (10.0, "shot", "#8 pointing here", 8),
        ]
        #expect(moments.count == expected.count)
        for (moment, want) in zip(moments, expected) {
            #expect(moment.at == want.0)
            #expect(moment.kind == want.1)
            #expect(moment.text == want.2)
            #expect(moment.shot == want.3)
        }
    }

    @Test func aClickInteractionFarFromItsShotIsKept() {
        let interactions = [Interaction(kind: .click, label: "button “Sign up”", time: at(4.2))]
        let shots = [shotRecord(2, "click", at: 6.0, element: "button “Sign up”")]
        let input = FeedbackWriter.Input(notes: "", shots: [], interactions: interactions, clockStart: t0)
        let moments = FeedbackWriter.timeline(input, shots: shots, video: nil, dir: URL(fileURLWithPath: "/tmp/none"))
        #expect(moments.map(\.kind) == ["click", "shot"])
    }

    // MARK: said(around:)

    @Test func saidAroundAShotIsWhatYouSaidUntilTheNextOne() {
        let words = [("the", 0.0), ("header", 0.4), ("looks", 0.8), ("fine", 1.2),
                     ("but", 1.6), ("this", 2.0), ("button", 5.0), ("is", 5.3), ("too", 5.6), ("big", 5.9)]
            .map { SpokenWord(text: $0.0, time: at($0.1)) }
        let shots = [makeShot(1, .screen, at: t0), makeShot(2, .pointer, at: at(1.7)), makeShot(3, .click, at: at(5.0))]
        let input = FeedbackWriter.Input(notes: "", shots: shots, words: words, clockStart: t0)
        // The opening screen never has words.
        #expect(FeedbackWriter.said(around: shots[0], in: input) == nil)
        // A quarter second of grace before the shot: "but" at 1.6 counts for a shot at 1.7.
        #expect(FeedbackWriter.said(around: shots[1], in: input) == "but this")
        #expect(FeedbackWriter.said(around: shots[2], in: input) == "button is too big")
    }

    @Test func saidAroundIsCappedAndNilWhenSilent() {
        let words = (0..<25).map { SpokenWord(text: "w\($0)", time: at(10 + Double($0) * 0.2)) }
        let shots = [makeShot(1, .pointer, at: at(1)), makeShot(2, .pointer, at: at(10)), makeShot(3, .screen, at: at(14))]
        let input = FeedbackWriter.Input(notes: "", shots: shots, words: words, clockStart: t0)
        #expect(FeedbackWriter.said(around: shots[0], in: input) == nil)
        #expect(FeedbackWriter.said(around: shots[1], in: input) == (0..<16).map { "w\($0)" }.joined(separator: " "))
        // A later whole-screen shot does get the words said around it.
        #expect(FeedbackWriter.said(around: shots[2], in: input) == "w19 w20 w21 w22 w23 w24")
    }

    // MARK: write

    @Test func writeMakesAFolderInTheInbox() throws {
        try withTemporaryInbox { root in
            let words = [("this", 0.0), ("button", 0.4), ("is", 0.8), ("too", 1.2), ("big", 1.6)]
                .map { SpokenWord(text: $0.0, time: at($0.1)) }
            var drawing = makeShot(2, .drawing, at: at(0.3), window: "Home", inside: ["button “Sign up”"])
            drawing.stroke = [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 4), CGPoint(x: 12, y: 9)]
            var click = makeShot(3, .click, at: at(1.3), element: "button “Sign up”")
            click.point = CGPoint(x: 5, y: 6)
            click.region = CGRect(x: 1, y: 2, width: 8, height: 4)
            let input = FeedbackWriter.Input(notes: "[#2] this button is too big [#3]",
                                             shots: [makeShot(1, .screen, at: t0), drawing, click], words: words,
                                             interactions: [Interaction(kind: .hover, label: "link “Cancel”", time: at(0.1))],
                                             clockStart: t0, liveNotes: "this button is to big", engine: "live")
            let (dir, record) = try FeedbackWriter.write(input)

            #expect(dir.deletingLastPathComponent().path == root.path)
            #expect(dir.lastPathComponent == record.id)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(files == ["1-screen.png", "2-drawing.png", "3-click.png", "feedback.json", "feedback.md"])

            #expect(record.notes == input.notes)
            #expect(record.engine == "live")
            #expect(record.liveNotes == "this button is to big")
            #expect(record.video == nil)
            #expect(record.shots.map(\.file) == ["1-screen.png", "2-drawing.png", "3-click.png"])
            #expect(record.shots[0].said == nil)
            #expect(record.shots[1].said == "button is too")
            #expect(record.shots[1].inside == ["button “Sign up”"])
            #expect(record.shots[1].at == 0.3)
            #expect(record.shots[2].said == "too big")
            #expect(record.shots[2].pointer == [5, 6])
            #expect(record.shots[2].region == [1, 2, 8, 4])
            #expect(record.timeline?.map(\.kind) == ["said", "hover", "shot", "shot"])

            // What's on disk reads back the same.
            let loaded = try #require(Inbox.load(dir))
            #expect(loaded.id == record.id)
            #expect(loaded.notes == record.notes)
            #expect(loaded.shots.map(\.said) == record.shots.map(\.said))
            #expect(Inbox.items().map(\.lastPathComponent) == [dir.lastPathComponent])
            let md = try String(contentsOf: dir.appendingPathComponent("feedback.md"), encoding: .utf8)
            #expect(md.contains("> [#2] this button is too big [#3]"))
            #expect(md.contains("- **#2 Drew on** · Safari — “Home”"))
        }
    }

    @Test func liveNotesAreDroppedWhenTheySayTheSame() throws {
        try withTemporaryInbox { _ in
            let input = FeedbackWriter.Input(notes: "The button [#1] is too big.", shots: [], clockStart: t0,
                                             liveNotes: "the button is too big", engine: "whisper")
            let (_, record) = try FeedbackWriter.write(input)
            #expect(record.liveNotes == nil)
            #expect(record.shots.isEmpty)
        }
    }

    @Test func writeNeverOverwritesAFolder() throws {
        try withTemporaryInbox { root in
            let input = FeedbackWriter.Input(notes: "one", shots: [], clockStart: t0)
            let first = try FeedbackWriter.write(input)
            let second = try FeedbackWriter.write(input)
            #expect(first.dir != second.dir)
            #expect(first.record.id != second.record.id)
            #expect(second.dir.deletingLastPathComponent().path == root.path)
            #expect(Inbox.items().map(\.lastPathComponent).sorted() == [first.record.id, second.record.id].sorted())
        }
    }
}
