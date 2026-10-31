import CoreGraphics
import Foundation

/// Turns the phone's raw touchscreen events (`getevent -lt`) into taps, long
/// presses, and swipes, in screen pixels.
struct TouchLog {
    struct Gesture {
        enum Kind { case tap, longPress, swipe(String) }
        let kind: Kind
        /// Where the finger went down, in screen pixels.
        let start: CGPoint
        let end: CGPoint
        let began: Date
        let ended: Date
    }

    /// Touchscreen device and its coordinate range, from `getevent -lp`.
    struct Screen {
        let path: String
        let maxX: Double
        let maxY: Double
        /// Where the last touch was. The kernel only reports a coordinate when it
        /// changes, so a tap on the same column as the last one sends no X.
        var x: Double = 0
        var y: Double = 0
    }

    /// Finds the touchscreen in `getevent -lp` output: the device that reports
    /// multitouch positions.
    static func touchscreen(in listing: String) -> Screen? {
        var path: String?
        var maxX: Double?, maxY: Double?
        var x: Double = 0, y: Double = 0
        for raw in listing.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("add device") {
                if let path, let maxX, let maxY { return Screen(path: path, maxX: maxX, maxY: maxY, x: x, y: y) }
                path = line.split(separator: " ").last.map(String.init)
                maxX = nil; maxY = nil
            } else if line.contains("ABS_MT_POSITION_X") {
                maxX = Self.number(after: "max ", in: line); x = Self.number(after: "value ", in: line) ?? 0
            } else if line.contains("ABS_MT_POSITION_Y") {
                maxY = Self.number(after: "max ", in: line); y = Self.number(after: "value ", in: line) ?? 0
            }
        }
        if let path, let maxX, let maxY { return Screen(path: path, maxX: maxX, maxY: maxY, x: x, y: y) }
        return nil
    }

    private static func number(after label: String, in line: String) -> Double? {
        guard let range = line.range(of: label) else { return nil }
        return Double(line[range.upperBound...].prefix { $0.isNumber })
    }

    let screen: Screen
    /// Phone screen size in pixels (portrait).
    let size: CGSize
    private(set) var gestures: [Gesture] = []

    private var x: Double = 0, y: Double = 0
    private var down: (start: CGPoint, at: Date)?
    private var last = CGPoint.zero
    /// Fingers on the glass, by multitouch slot, plus BTN_TOUCH for phones without slots.
    private var slot = 0
    private var fingers: Set<Int> = []
    private var button = false

    init(screen: Screen, size: CGSize) {
        self.screen = screen
        self.size = size
        x = screen.x
        y = screen.y
    }

    /// One line of `getevent -lt <device>`, e.g. `[  5423.12] EV_ABS ABS_MT_POSITION_X 000001a3`.
    /// Fingers going down or up are settled at the end of each frame (SYN_REPORT),
    /// since a frame can lift one finger id and place another.
    mutating func feed(_ line: String, at time: Date = Date()) {
        let body = line.split(separator: "]", maxSplits: 1).last.map(String.init) ?? line
        var parts = body.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.first?.hasPrefix("/dev/") == true { parts.removeFirst() }
        guard parts.count >= 3 else { return }
        let (code, value) = (parts[1], parts[2])
        switch code {
        case "ABS_MT_SLOT":
            slot = Int(UInt32(value, radix: 16) ?? 0)
        case "ABS_MT_POSITION_X":
            if slot == fingers.min() ?? slot { x = Double(UInt32(value, radix: 16) ?? 0) }
        case "ABS_MT_POSITION_Y":
            if slot == fingers.min() ?? slot { y = Double(UInt32(value, radix: 16) ?? 0) }
        case "ABS_MT_TRACKING_ID":
            if value == "ffffffff" { fingers.remove(slot) } else { fingers.insert(slot) }
        case "BTN_TOUCH":
            button = value == "DOWN"
        case "SYN_REPORT":
            last = point
            let touching = !fingers.isEmpty || button
            if touching, down == nil { down = (last, time) }
            if !touching, down != nil { end(at: time) }
        default: break
        }
    }

    private var point: CGPoint {
        CGPoint(x: x / max(screen.maxX, 1) * size.width, y: y / max(screen.maxY, 1) * size.height)
    }

    private mutating func end(at time: Date) {
        guard let started = down else { return }
        down = nil
        let start = started.start
        let end = last
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let held = time.timeIntervalSince(started.at)
        let slop = size.width * 0.04
        let kind: Gesture.Kind
        if distance < slop {
            kind = held >= 0.5 ? .longPress : .tap
        } else if abs(dx) > abs(dy) {
            kind = .swipe(dx > 0 ? "right" : "left")
        } else {
            kind = .swipe(dy > 0 ? "down" : "up")
        }
        gestures.append(Gesture(kind: kind, start: start, end: end, began: started.at, ended: time))
    }
}
