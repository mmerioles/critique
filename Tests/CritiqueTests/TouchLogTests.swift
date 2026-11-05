import CoreGraphics
import Foundation
import Testing
@testable import Critique

struct TouchLogTests {
    /// `getevent -lp` on a phone with buttons listed before the touchscreen.
    static let listing = """
    add device 1: /dev/input/event1
      name:     "gpio-keys"
      events:
        KEY (0001): KEY_VOLUMEDOWN        KEY_VOLUMEUP
      input props:
        <none>
    add device 2: /dev/input/event5
      name:     "fts_ts"
      events:
        KEY (0001): BTN_TOUCH             BTN_TOOL_FINGER
        ABS (0003): ABS_MT_SLOT           : value 0, min 0, max 9, fuzz 0, flat 0, resolution 0
                    ABS_MT_TOUCH_MAJOR    : value 0, min 0, max 255, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_X     : value 540, min 0, max 1079, fuzz 0, flat 0, resolution 0
                    ABS_MT_POSITION_Y     : value 1200, min 0, max 2399, fuzz 0, flat 0, resolution 0
                    ABS_MT_TRACKING_ID    : value 0, min 0, max 65535, fuzz 0, flat 0, resolution 0
      input props:
        INPUT_PROP_DIRECT
    add device 3: /dev/input/event2
      name:     "uinput-fpc"
      events:
        KEY (0001): KEY_UP                KEY_DOWN
      input props:
        <none>

    """

    @Test func findsTheTouchscreenInTheListing() throws {
        let screen = try #require(TouchLog.touchscreen(in: Self.listing))
        #expect(screen.path == "/dev/input/event5")
        #expect(screen.maxX == 1079)
        #expect(screen.maxY == 2399)
        #expect(screen.x == 540)
        #expect(screen.y == 1200)
    }

    @Test func touchscreenListedLast() throws {
        // No "add device" after it: found when the listing ends.
        let lines = Self.listing.split(separator: "\n").map(String.init)
        let end = lines.firstIndex { $0.contains("add device 3") }!
        let screen = try #require(TouchLog.touchscreen(in: lines[..<end].joined(separator: "\n")))
        #expect(screen.path == "/dev/input/event5")
    }

    @Test func noTouchscreen() {
        let listing = """
        add device 1: /dev/input/event1
          name:     "gpio-keys"
          events:
            KEY (0001): KEY_VOLUMEDOWN        KEY_VOLUMEUP
        """
        #expect(TouchLog.touchscreen(in: listing) == nil)
        #expect(TouchLog.touchscreen(in: "") == nil)
    }

    // MARK: Gestures

    static let screen = TouchLog.Screen(path: "/dev/input/event5", maxX: 1079, maxY: 2399)
    static let size = CGSize(width: 1080, height: 2400)
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func hex(_ n: Int) -> String { String(format: "%08x", n) }

    /// Lines as `getevent -lt /dev/input/event5` prints them for a finger down at (x, y).
    static func down(x: Int, y: Int, id: Int = 0x42, slot: Int = 0) -> [String] {
        ["[   12345.678901] EV_ABS       ABS_MT_SLOT          \(hex(slot))",
         "[   12345.678901] EV_ABS       ABS_MT_TRACKING_ID   \(hex(id))",
         "[   12345.678901] EV_KEY       BTN_TOUCH            DOWN",
         "[   12345.678901] EV_KEY       BTN_TOOL_FINGER      DOWN",
         "[   12345.678901] EV_ABS       ABS_MT_POSITION_X    \(hex(x))",
         "[   12345.678901] EV_ABS       ABS_MT_POSITION_Y    \(hex(y))",
         "[   12345.678901] EV_ABS       ABS_MT_TOUCH_MAJOR   00000005",
         "[   12345.678901] EV_SYN       SYN_REPORT           00000000"]
    }

    static func move(x: Int? = nil, y: Int? = nil) -> [String] {
        var lines: [String] = []
        if let x { lines.append("[   12345.700000] EV_ABS       ABS_MT_POSITION_X    \(hex(x))") }
        if let y { lines.append("[   12345.700000] EV_ABS       ABS_MT_POSITION_Y    \(hex(y))") }
        lines.append("[   12345.700000] EV_SYN       SYN_REPORT           00000000")
        return lines
    }

    static let up = ["[   12345.800000] EV_ABS       ABS_MT_TRACKING_ID   ffffffff",
                     "[   12345.800000] EV_KEY       BTN_TOUCH            UP",
                     "[   12345.800000] EV_KEY       BTN_TOOL_FINGER      UP",
                     "[   12345.800000] EV_SYN       SYN_REPORT           00000000"]

    static func feed(_ log: inout TouchLog, _ lines: [String], at offset: TimeInterval) {
        for line in lines { log.feed(line, at: t0.addingTimeInterval(offset)) }
    }

    func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1.5 && abs(a.y - b.y) < 1.5 }

    @Test func tap() throws {
        var log = TouchLog(screen: Self.screen, size: Self.size)
        Self.feed(&log, Self.down(x: 540, y: 1200), at: 0)
        #expect(log.gestures.isEmpty)
        Self.feed(&log, Self.up, at: 0.12)
        let gesture = try #require(log.gestures.first)
        guard case .tap = gesture.kind else { Issue.record("expected a tap, got \(gesture.kind)"); return }
        #expect(near(gesture.start, CGPoint(x: 540, y: 1200)))
        #expect(near(gesture.end, gesture.start))
        #expect(gesture.began == Self.t0)
        #expect(gesture.ended == Self.t0.addingTimeInterval(0.12))
        #expect(log.gestures.count == 1)
    }

    @Test func longPress() throws {
        var log = TouchLog(screen: Self.screen, size: Self.size)
        Self.feed(&log, Self.down(x: 100, y: 200), at: 0)
        Self.feed(&log, Self.move(x: 110, y: 205), at: 0.3) // a little wobble is still a press
        Self.feed(&log, Self.up, at: 0.7)
        let gesture = try #require(log.gestures.first)
        guard case .longPress = gesture.kind else { Issue.record("expected a long press, got \(gesture.kind)"); return }
        #expect(near(gesture.start, CGPoint(x: 100, y: 200)))
    }

    @Test func swipes() throws {
        var log = TouchLog(screen: Self.screen, size: Self.size)
        Self.feed(&log, Self.down(x: 200, y: 1200), at: 0)
        Self.feed(&log, Self.move(x: 500), at: 0.1)
        Self.feed(&log, Self.move(x: 800, y: 1230), at: 0.2)
        Self.feed(&log, Self.up, at: 0.3)
        Self.feed(&log, Self.down(x: 540, y: 2000), at: 1)
        Self.feed(&log, Self.move(y: 800), at: 1.2)
        Self.feed(&log, Self.up, at: 1.3)
        Self.feed(&log, Self.down(x: 900, y: 1000), at: 2)
        Self.feed(&log, Self.move(x: 300), at: 2.1)
        Self.feed(&log, Self.up, at: 2.2)
        Self.feed(&log, Self.down(x: 540, y: 400), at: 3)
        Self.feed(&log, Self.move(y: 1400), at: 3.1)
        Self.feed(&log, Self.up, at: 3.2)
        #expect(log.gestures.count == 4)
        var directions: [String] = []
        for gesture in log.gestures {
            guard case .swipe(let direction) = gesture.kind else { Issue.record("expected a swipe, got \(gesture.kind)"); return }
            directions.append(direction)
        }
        #expect(directions == ["right", "up", "left", "down"])
        #expect(near(log.gestures[0].start, CGPoint(x: 200, y: 1200)))
        #expect(near(log.gestures[0].end, CGPoint(x: 800, y: 1230)))
    }

    @Test func tapOnTheSameColumnSendsNoX() throws {
        // The kernel only reports a coordinate when it changes.
        var log = TouchLog(screen: Self.screen, size: Self.size)
        Self.feed(&log, Self.down(x: 540, y: 300), at: 0)
        Self.feed(&log, Self.up, at: 0.1)
        Self.feed(&log, ["[   12345.900000] EV_ABS       ABS_MT_TRACKING_ID   00000043",
                         "[   12345.900000] EV_KEY       BTN_TOUCH            DOWN",
                         "[   12345.900000] EV_ABS       ABS_MT_POSITION_Y    \(Self.hex(900))",
                         "[   12345.900000] EV_SYN       SYN_REPORT           00000000"], at: 1)
        Self.feed(&log, Self.up, at: 1.1)
        #expect(log.gestures.count == 2)
        #expect(near(log.gestures[1].start, CGPoint(x: 540, y: 900)))
    }

    @Test func startsFromTheListingsLastPosition() throws {
        // A tap right where the last one was sends no coordinates at all.
        let screen = TouchLog.Screen(path: "/dev/input/event5", maxX: 1079, maxY: 2399, x: 540, y: 1200)
        var log = TouchLog(screen: screen, size: Self.size)
        Self.feed(&log, ["[   12345.900000] EV_ABS       ABS_MT_TRACKING_ID   00000043",
                         "[   12345.900000] EV_SYN       SYN_REPORT           00000000"], at: 0)
        Self.feed(&log, Self.up, at: 0.1)
        let gesture = try #require(log.gestures.first)
        #expect(near(gesture.start, CGPoint(x: 540, y: 1200)))
    }

    @Test func linesWithTheDevicePath() throws {
        // `getevent -lt` with no device argument prefixes each line with the device.
        var log = TouchLog(screen: Self.screen, size: Self.size)
        let prefixed = (Self.down(x: 300, y: 600) + Self.up).map {
            $0.replacingOccurrences(of: "] EV_", with: "] /dev/input/event5: EV_")
        }
        Self.feed(&log, prefixed, at: 0)
        let gesture = try #require(log.gestures.first)
        guard case .tap = gesture.kind else { Issue.record("expected a tap, got \(gesture.kind)"); return }
        #expect(near(gesture.start, CGPoint(x: 300, y: 600)))
    }

    @Test func secondFingerDoesNotMoveTheFirst() throws {
        var log = TouchLog(screen: Self.screen, size: Self.size)
        Self.feed(&log, Self.down(x: 300, y: 600, id: 1, slot: 0), at: 0)
        Self.feed(&log, Self.down(x: 900, y: 1800, id: 2, slot: 1), at: 0.05)
        // Lift both in one frame.
        Self.feed(&log, ["[   12345.900000] EV_ABS       ABS_MT_SLOT          00000000",
                         "[   12345.900000] EV_ABS       ABS_MT_TRACKING_ID   ffffffff",
                         "[   12345.900000] EV_ABS       ABS_MT_SLOT          00000001",
                         "[   12345.900000] EV_ABS       ABS_MT_TRACKING_ID   ffffffff",
                         "[   12345.900000] EV_KEY       BTN_TOUCH            UP",
                         "[   12345.900000] EV_SYN       SYN_REPORT           00000000"], at: 0.1)
        #expect(log.gestures.count == 1)
        let gesture = try #require(log.gestures.first)
        guard case .tap = gesture.kind else { Issue.record("expected a tap, got \(gesture.kind)"); return }
        #expect(near(gesture.start, CGPoint(x: 300, y: 600)))
    }

    @Test func ignoresNoise() {
        var log = TouchLog(screen: Self.screen, size: Self.size)
        log.feed("", at: Self.t0)
        log.feed("[   12345.678901] EV_SYN       SYN_REPORT", at: Self.t0)
        log.feed("add device 1: /dev/input/event5", at: Self.t0)
        log.feed("[   12345.678901] EV_KEY       BTN_TOUCH            UP", at: Self.t0)
        log.feed("[   12345.678901] EV_SYN       SYN_REPORT           00000000", at: Self.t0)
        #expect(log.gestures.isEmpty)
    }
}
