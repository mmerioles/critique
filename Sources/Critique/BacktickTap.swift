import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Detects a double-tap of the ` key (the one above Tab): start a critique, and
/// double-tap again to send. Holding ` still draws during a session.
///
/// Watches keys with a listen-only event tap (needs Input Monitoring), so it never
/// blocks your typing:
/// - Three quick backticks (a Markdown code fence) don't count.
/// - If the double-tap typed `` into a text field, those two characters are deleted.
@MainActor
final class BacktickTap {
    private let onDoubleTap: () -> Void
    private let inSession: () -> Bool
    private var tap: CFMachPort?
    private var retryTimer: Timer?

    private var downAt: TimeInterval?         // ` held since
    private var lastTapAt: TimeInterval = 0   // when the last quick tap was released
    private var pending: DispatchWorkItem?    // double-tap waiting to see if a third ` follows

    private let maxHold: TimeInterval = 0.25  // longer than this is a hold (drawing), not a tap
    private let maxGap: TimeInterval = 0.4
    private let fenceWait: TimeInterval = 0.25
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    var isActive: Bool { tap != nil }

    init(inSession: @escaping () -> Bool, onDoubleTap: @escaping () -> Void) {
        self.inSession = inSession
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
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                           callback: { _, type, event, refcon in
            let me = Unmanaged<BacktickTap>.fromOpaque(refcon!).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let modified = !event.flags.intersection(BacktickTap.modifiers).isEmpty
            MainActor.assumeIsolated { me.handle(type, keyCode: keyCode, repeated: repeated, modified: modified) }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, keyCode: Int64, repeated: Bool, modified: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let isBacktick = keyCode == Int64(kVK_ANSI_Grave)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown where isBacktick && !modified:
            if repeated { return }
            if pending != nil {
                // A third ` right away: it's a code fence, not a trigger.
                pending?.cancel()
                pending = nil
                lastTapAt = 0
            }
            downAt = now
        case .keyUp where isBacktick:
            guard let down = downAt else { return }
            downAt = nil
            guard now - down < maxHold else { lastTapAt = 0; return } // held to draw
            guard now - lastTapAt < maxGap + maxHold else { lastTapAt = now; return }
            lastTapAt = 0
            if inSession() {
                onDoubleTap() // ` is captured during a session, so nothing was typed
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pending = nil
                    Self.deleteTypedBackticks()
                    self.onDoubleTap()
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + fenceWait, execute: work)
            }
        case .keyUp:
            break
        default:
            // Any other key or a click breaks the sequence.
            downAt = nil
            lastTapAt = 0
            pending?.cancel()
            pending = nil
        }
    }

    /// The double-tap typed `` wherever you were typing. Take them back out,
    /// but only when a text field has focus, so nothing else gets a Delete.
    private static func deleteTypedBackticks() {
        guard focusedElementIsText() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<2 {
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
    }

    private static func focusedElementIsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let name = role as? String ?? ""
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(name)
    }
}
