import Foundation

/// Feedback lives on disk so any agent can read it:
///   ~/.critique/inbox/<id>/feedback.md      ← human/agent-readable summary
///   ~/.critique/inbox/<id>/feedback.json    ← structured version
///   ~/.critique/inbox/<id>/*.png            ← screenshots (highlights are annotated)
struct FeedbackRecord: Codable {
    struct ShotRecord: Codable {
        var number: Int
        var kind: String
        var file: String
        var zoomFile: String?
        var app: String?
        var window: String?
        /// x, y, width, height in screenshot pixels
        var region: [Int]?
        /// x, y of the cursor in screenshot pixels
        var pointer: [Int]?
        /// What was under the cursor, e.g. `button “Sign up”`
        var element: String?
        /// Seconds from the start of the recording
        var at: Double?
        /// What the user was saying while pointing at this
        var said: String?
        /// Interactive elements inside what they drew
        var inside: [String]?
    }

    /// One moment in the session, on the screen recording's clock.
    struct Moment: Codable {
        /// Seconds from the start of the recording
        var at: Double
        /// said, hover, click, or shot
        var kind: String
        var text: String
        /// Screenshot number, for kind == shot
        var shot: Int?
        /// A frame pulled from the recording at this moment (file in the folder)
        var frame: String?
    }

    var id: String
    var createdAt: Date
    var notes: String
    var shots: [ShotRecord]
    /// Screen recording with the user's voice (file name in the same folder)
    var video: String?
    var duration: Double?
    var timeline: [Moment]?
    /// Just the user's voice (file name in the same folder)
    var audio: String?
    /// What live dictation heard, when it differs from `notes`
    var liveNotes: String?
    /// Which speech engine produced `notes`
    var engine: String?

    func markdown(in dir: URL) -> String {
        var md = "# UX feedback · \(Self.displayDate.string(from: createdAt))\n\n"
        md += "Recorded with Critique while the user talked over their screen — treat it like a teammate "
        md += "screen-sharing with you. They use their cursor like a finger: red boxes and red strokes mark what "
        md += "they pointed at, drew on, or clicked. Markers like [#2] in their words show which screenshot they "
        md += "were pointing at as they said it. The timeline lines up their words, what they hovered and clicked, "
        md += "and the screen recording. Look at the images before changing code.\n\n"

        md += "## What they said\n\n"
        let words = notes.replacingOccurrences(of: #"\[#\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        md += words.isEmpty ? "_(Nothing was said — follow the timeline and screenshots.)_\n\n"
            : notes.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        if !words.isEmpty || audio != nil {
            md += "_Speech-to-text can mishear words (e.g. “read me” = README, “whisper flow” = Wispr Flow). "
            md += "Use context to work out what they meant"
            if let audio { md += ", or listen to their voice: `\(dir.appendingPathComponent(audio).path)`" }
            md += "._\n\n"
        }
        if let liveNotes {
            md += "### Also heard live (a second transcript — compare if something seems off)\n\n"
            md += liveNotes.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        }

        if let timeline, !timeline.isEmpty {
            md += "## Timeline\n\n"
            for moment in timeline {
                md += "- **\(Self.clock(moment.at, tenths: true))** "
                switch moment.kind {
                case "said": md += "said “\(moment.text)”"
                case "hover": md += "hovered \(moment.text)"
                case "click": md += "clicked \(moment.text)"
                default: md += moment.text
                }
                if let frame = moment.frame { md += " · frame: `\(dir.appendingPathComponent(frame).path)`" }
                md += "\n"
            }
            md += "\n"
        }

        if let video {
            let path = dir.appendingPathComponent(video).path
            md += "## Screen recording\n\n"
            md += "`\(path)` — \(Self.clock(duration ?? 0)) of their screen with their voice; times above match it. "
            md += "To see a moment: `ffmpeg -ss 4 -i \"\(path)\" -frames:v 1 /tmp/frame.png`\n\n"
        }

        md += "## Screenshots\n\n"
        for shot in shots {
            var context = shot.app ?? "Unknown app"
            if let window = shot.window { context += " — “\(window)”" }
            md += "- **#\(shot.number) \(Self.label(shot.kind))**\(shot.element.map { " \($0)" } ?? "") · \(context)\n"
            if let inside = shot.inside, !inside.isEmpty { md += "  - Inside the drawing: \(inside.joined(separator: ", "))\n" }
            md += "  - Image: `\(dir.appendingPathComponent(shot.file).path)`\n"
            if let zoom = shot.zoomFile { md += "  - Zoomed in: `\(dir.appendingPathComponent(zoom).path)`\n" }
            if let r = shot.region, r.count == 4 { md += "  - Box: \(r[2])×\(r[3]) px at (\(r[0]), \(r[1]))\n" }
            if let p = shot.pointer, p.count == 2 { md += "  - Cursor at: (\(p[0]), \(p[1])) px\n" }
        }
        return md
    }

    static func label(_ kind: String) -> String {
        ["drawing": "Drew on", "highlight": "Circled", "pointer": "Pointing at", "click": "Clicked"][kind] ?? "Screen"
    }

    static func clock(_ seconds: Double, tenths: Bool = false) -> String {
        if tenths {
            let t = Int((seconds * 10).rounded())
            return String(format: "%d:%02d.%d", t / 600, (t / 10) % 60, t % 10)
        }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static let displayDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm:ss a"
        return f
    }()
}

enum Inbox {
    static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["CRITIQUE_HOME"] {
            return URL(fileURLWithPath: custom).appendingPathComponent("inbox")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".critique/inbox")
    }

    /// Feedback folders, newest first.
    static func items() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("feedback.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func load(_ dir: URL) -> FeedbackRecord? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("feedback.json")) else { return nil }
        return try? decoder.decode(FeedbackRecord.self, from: data)
    }

    static func save(_ record: FeedbackRecord, in dir: URL) throws {
        try encoder.encode(record).write(to: dir.appendingPathComponent("feedback.json"))
        try record.markdown(in: dir).write(to: dir.appendingPathComponent("feedback.md"), atomically: true, encoding: .utf8)
    }

    static func isSeen(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".seen").path)
    }

    static func markSeen(_ dir: URL) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".seen").path, contents: nil)
    }

    static func newID(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
