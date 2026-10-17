import CoreGraphics
import Foundation

struct Shot {
    enum Kind: String, Codable {
        case screen      // whole screen
        case drawing     // you held ` and drew on the screen
        case pointer     // your cursor rested on something while you talked
        case click       // you clicked something
    }
    let number: Int
    let kind: Kind
    let image: CGImage
    /// Boxed area in image pixels, top-left origin.
    var region: CGRect? = nil
    /// Cursor position in image pixels, top-left origin.
    var point: CGPoint? = nil
    let app: String?
    let window: String?
    /// What was under the cursor, e.g. `button “Sign up”`.
    var element: String? = nil
    /// The stroke you drew, in image pixels (top-left origin).
    var stroke: [CGPoint]? = nil
    /// Buttons, links, fields… inside what you drew.
    var inside: [String] = []
    /// When you pointed at it.
    var time = Date()
}

/// When a word was spoken, as an offset into the transcript text.
struct WordTime {
    let offset: Int
    var length = 0
    let time: Date
}

/// Something you hovered or clicked — logged even when no screenshot is taken,
/// so the agent can line it up with the screen recording.
struct Interaction {
    enum Kind: String { case hover, click }
    let kind: Kind
    let label: String
    let time: Date
}

struct SpokenWord {
    let text: String
    let time: Date
}

/// Everything captured during one feedback session.
@MainActor
final class Session: ObservableObject {
    enum Mode: Equatable {
        case idle, listening, typing
        case sent(String)
        case notice(String)
    }

    private struct Marker {
        let number: Int
        let time: Date
    }

    @Published var mode: Mode = .idle
    /// Finished text (and everything you typed). Editable while typing.
    @Published var committed = ""
    @Published var level: Float = 0
    @Published var micAvailable = true
    @Published private(set) var shots: [Shot] = []
    /// Recent mic levels, oldest first, for the waveform.
    @Published var levels = [Float](repeating: 0, count: 28)
    /// True while you hold ` to draw.
    @Published var isDrawing = false
    private(set) var interactions: [Interaction] = []
    private(set) var startedAt = Date()
    /// Every finished word with when you said it — used to build the timeline.
    private(set) var spoken: [SpokenWord] = []

    // Speech still being recognized, plus markers waiting to be placed in it.
    @Published private var speech = ""
    private var words: [WordTime] = []
    private var markers: [Marker] = []

    var isActive: Bool {
        switch mode {
        case .listening, .typing: return true
        default: return false
        }
    }

    /// The in-progress speech with [#n] markers placed where you pointed.
    var live: String { Self.place(markers, in: speech, words: words, trailing: true).text }
    var transcript: String { Self.join(committed, live) }

    func updateSpeech(_ text: String, words: [WordTime]) {
        speech = text
        self.words = words
    }

    /// Moves recognized speech into `committed`. Markers that came after the last
    /// word wait for the next words you say.
    func commitSpeech() {
        let ns = speech as NSString
        for word in words where word.length > 0 && word.offset + word.length <= ns.length {
            spoken.append(SpokenWord(text: ns.substring(with: NSRange(location: word.offset, length: word.length)), time: word.time))
        }
        let result = Self.place(markers, in: speech, words: words, trailing: false)
        committed = Self.join(committed, result.text)
        markers = result.leftover
        speech = ""
        words = []
    }

    /// Commits everything, putting any leftover markers at the end.
    func finalizeText() {
        commitSpeech()
        for marker in markers { committed = Self.join(committed, "[#\(marker.number)]") }
        markers = []
    }

    /// Adds a screenshot. `at` is when you pointed, so its [#n] lands next to the
    /// words you were saying then. While typing, the marker goes at the end of your text.
    @discardableResult
    func addShot(_ make: (Int) -> Shot, at time: Date? = nil) -> Int {
        var shot = make(shots.count + 1)
        shot.time = time ?? startedAt
        shots.append(shot)
        if let time {
            if mode == .typing || !micAvailable {
                committed = Self.join(committed, "[#\(shot.number)]")
            } else {
                markers.append(Marker(number: shot.number, time: time))
            }
        }
        return shot.number
    }

    /// Replaces what you said with a better transcript (from the recording),
    /// re-placing each [#n] marker by when you pointed.
    func replaceTranscript(with words: [SpokenWord]) {
        spoken = words.sorted { $0.time < $1.time }
        var pending = shots.filter { $0.kind != .screen }.sorted { $0.time < $1.time }
        var parts: [String] = []
        for word in spoken {
            while let next = pending.first, next.time <= word.time {
                parts.append("[#\(next.number)]")
                pending.removeFirst()
            }
            parts.append(word.text)
        }
        parts += pending.map { "[#\($0.number)]" }
        committed = parts.joined(separator: " ")
        speech = ""
        self.words = []
        markers = []
    }

    func log(_ kind: Interaction.Kind, _ label: String, at time: Date = Date()) {
        // Hovering the same thing again isn't news.
        if kind == .hover, interactions.last(where: { $0.kind == .hover })?.label == label { return }
        guard interactions.count < 200 else { return }
        interactions.append(Interaction(kind: kind, label: label, time: time))
    }

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        committed = ""
        speech = ""
        words = []
        markers = []
        level = 0
        shots = []
        spoken = []
        interactions = []
        isDrawing = false
        levels = [Float](repeating: 0, count: levels.count)
        startedAt = Date()
        micAvailable = true
    }

    private static func place(_ markers: [Marker], in text: String, words: [WordTime],
                              trailing: Bool) -> (text: String, leftover: [Marker]) {
        let ns = NSMutableString(string: text)
        var inserts: [(offset: Int, number: Int)] = []
        var leftover: [Marker] = []
        for marker in markers {
            if let word = words.first(where: { $0.time >= marker.time }) {
                inserts.append((min(word.offset, ns.length), marker.number))
            } else if trailing {
                inserts.append((ns.length, marker.number))
            } else {
                leftover.append(marker)
            }
        }
        // Insert from the end so earlier offsets stay valid.
        for insert in inserts.sorted(by: { ($0.offset, $0.number) > ($1.offset, $1.number) }) {
            let atEnd = insert.offset >= ns.length
            ns.insert(atEnd ? " [#\(insert.number)]" : "[#\(insert.number)] ", at: insert.offset)
        }
        return (ns.trimmingCharacters(in: .whitespaces), leftover)
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + (a.hasSuffix("\n") ? "" : " ") + b
    }
}
