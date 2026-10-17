import AppKit
import Carbon.HIToolbox

/// Detects a double-tap of the right Option key (like Wispr Flow's trigger).
/// A modifier key on its own can only be seen with a listen-only event tap,
/// which needs the Input Monitoring permission.
@MainActor
final class RightOptionTap {
    private let onDoubleTap: () -> Void
    private var tap: CFMachPort?
    private var retryTimer: Timer?

    private var downAt: TimeInterval?        // right Option currently held since
    private var lastTapAt: TimeInterval = 0  // when the last clean tap ended
    private var interrupted = false          // another key was used during the press

    private let maxHold: TimeInterval = 0.35
    private let maxGap: TimeInterval = 0.4
    private static let rightOptionMask: UInt64 = 0x40 // NX_DEVICERALTKEYMASK

    var isActive: Bool { tap != nil }

    init(onDoubleTap: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !install() {
            // Keep trying quietly until Input Monitoring is allowed.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.install() else { return }
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                }
            }
        }
    }

    private func install() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                           callback: { _, type, event, refcon in
            let me = Unmanaged<RightOptionTap>.fromOpaque(refcon!).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            MainActor.assumeIsolated { me.handle(type, keyCode: keyCode, flags: flags) }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, keyCode: Int64, flags: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown, .leftMouseDown:
            // Option used as a modifier (e.g. ⌥H) — not a tap.
            interrupted = true
            lastTapAt = 0
        case .flagsChanged where keyCode == Int64(kVK_RightOption):
            if flags & Self.rightOptionMask != 0 { // pressed
                downAt = now
                interrupted = false
            } else if let down = downAt {          // released
                downAt = nil
                guard !interrupted, now - down < maxHold else { lastTapAt = 0; return }
                if now - lastTapAt < maxGap + maxHold {
                    lastTapAt = 0
                    onDoubleTap()
                } else {
                    lastTapAt = now
                }
            }
        case .flagsChanged:
            // Any other modifier pressed in between breaks the sequence.
            interrupted = true
            lastTapAt = 0
        default:
            break
        }
    }
}
