import CoreGraphics
import Foundation
@testable import Critique

private let inboxLock = NSLock()

/// Points `Inbox.root` at a fresh temporary inbox for the duration of `body`, then
/// removes it. Callers are serialized, since the root is process-wide.
func withTemporaryInbox<T>(_ body: (URL) throws -> T) rethrows -> T {
    inboxLock.lock()
    defer { inboxLock.unlock() }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("critique-tests-\(UUID().uuidString)")
    let root = home.appendingPathComponent("inbox")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    Inbox.overrideRoot = root
    defer {
        Inbox.overrideRoot = nil
        try? FileManager.default.removeItem(at: home)
    }
    return try body(root)
}

/// A fresh temporary folder, removed after `body`.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("critique-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// A small solid image, for shots.
func tinyImage(width: Int = 16, height: Int = 12) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

func makeShot(_ number: Int, _ kind: Shot.Kind, at time: Date, app: String? = "Safari", window: String? = nil,
              element: String? = nil, inside: [String] = []) -> Shot {
    var shot = Shot(number: number, kind: kind, image: tinyImage(), app: app, window: window)
    shot.element = element
    shot.inside = inside
    shot.time = time
    return shot
}

/// Each word of `text`, said `step` seconds apart from `start`.
func spokenWords(_ text: String, from start: Date, step: TimeInterval = 0.5) -> [SpokenWord] {
    text.split(separator: " ").enumerated().map { i, word in
        SpokenWord(text: String(word), time: start.addingTimeInterval(Double(i) * step))
    }
}

/// Word times for `text` as the recognizer would report them: one per word, with
/// its offset into the text, said `step` seconds apart from `start`.
func wordTimes(_ text: String, from start: Date, step: TimeInterval = 0.5) -> [WordTime] {
    let ns = text as NSString
    var times: [WordTime] = []
    var location = 0
    for (i, word) in text.split(separator: " ").enumerated() {
        let range = ns.range(of: String(word), options: [], range: NSRange(location: location, length: ns.length - location))
        times.append(WordTime(offset: range.location, length: range.length, time: start.addingTimeInterval(Double(i) * step)))
        location = range.location + range.length
    }
    return times
}

/// A fully filled-in record, for save/load and markdown checks.
func sampleRecord(createdAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> FeedbackRecord {
    var shot = FeedbackRecord.ShotRecord(number: 1, kind: "drawing", file: "1-drawing.png", app: "Safari", window: "Home")
    shot.region = [10, 20, 300, 40]
    shot.pointer = [15, 25]
    shot.element = "button “Sign up”"
    shot.at = 4.2
    shot.said = "this button is way too big"
    shot.inside = ["button “Sign up”", "link “Cancel”"]
    var record = FeedbackRecord(id: Inbox.newID(for: createdAt), createdAt: createdAt,
                                notes: "The header looks fine but [#1] this button is way too big.", shots: [shot])
    record.video = "recording.mov"
    record.duration = 12.5
    record.audio = "voice.m4a"
    record.engine = "whisper"
    record.liveNotes = "The header looks fine but this button is way to big."
    record.timeline = [
        .init(at: 0.0, kind: "said", text: "The header looks fine but"),
        .init(at: 0.9, kind: "click", text: "menu button “File”"),
        .init(at: 1.6, kind: "hover", text: "menu item “Export…”", frame: "frames/0-01.8.jpg"),
        .init(at: 4.2, kind: "shot", text: "#1 drew around button “Sign up”, link “Cancel”", shot: 1),
    ]
    record.project = .init(name: "mmerioles/critique", path: "/Users/me/repos/critique", branch: "main",
                           remote: "git@github.com:mmerioles/critique.git")
    record.before = Rewind.Point(head: "abc123", branch: "main", snapshot: "def456")
    record.device = .init(model: "Pixel 8", serial: "ABCD1234", app: "bordgame.app", activity: ".MainActivity", reinstalls: true)
    return record
}
