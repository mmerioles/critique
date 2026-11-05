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

    private var detector = BacktickDetector()
    private var pending: DispatchWorkItem?    // double-tap waiting to see if a third ` follows

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
            act(on: detector.keyDown(at: now, repeated: repeated))
        case .keyUp where isBacktick:
            act(on: detector.keyUp(at: now, inSession: inSession()))
        case .keyUp:
            break
        default:
            // Any other key or a click breaks the sequence.
            act(on: detector.reset())
        }
    }

    private func act(on action: BacktickDetector.Action) {
        switch action {
        case .none, .hold:
            break
        case .trigger:
            onDoubleTap() // ` is captured during a session, so nothing was typed
        case .armFence:
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                guard self.detector.fenceElapsed() == .trigger else { return }
                Self.deleteTypedBackticks()
                self.onDoubleTap()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + detector.fenceWait, execute: work)
        case .cancelFence:
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

/// The timing behind the ` double-tap, kept apart from the event tap so it can be tested.
/// Feed it key downs and ups (in seconds, any clock) and act on what comes back.
struct BacktickDetector {
    enum Action: Equatable {
        case none
        /// ` was held longer than a tap: you're drawing, not triggering.
        case hold
        /// Two quick taps during a session: trigger right away.
        case trigger
        /// Two quick taps outside a session typed ``: wait `fenceWait` for a third `
        /// (a code fence), then call `fenceElapsed()` to see if it still counts.
        case armFence
        /// A third ` (or another key) arrived while waiting: it's a code fence, not a trigger.
        case cancelFence
    }

    var maxHold: TimeInterval = 0.25  // longer than this is a hold (drawing), not a tap
    var maxGap: TimeInterval = 0.4
    var fenceWait: TimeInterval = 0.25

    private static let never: TimeInterval = -.infinity
    private var downAt: TimeInterval?         // ` held since
    private var lastTapAt = never             // when the last quick tap was released
    private var fenceArmed = false            // double-tap waiting to see if a third ` follows

    mutating func keyDown(at now: TimeInterval, repeated: Bool = false) -> Action {
        if repeated { return .none }
        var action = Action.none
        if fenceArmed {
            // A third ` right away: it's a code fence, not a trigger.
            fenceArmed = false
            lastTapAt = Self.never
            action = .cancelFence
        }
        downAt = now
        return action
    }

    mutating func keyUp(at now: TimeInterval, inSession: Bool) -> Action {
        guard let down = downAt else { return .none }
        downAt = nil
        guard now - down < maxHold else { lastTapAt = Self.never; return .hold } // held to draw
        guard now - lastTapAt < maxGap + maxHold else { lastTapAt = now; return .none }
        lastTapAt = Self.never
        if inSession { return .trigger }
        fenceArmed = true
        return .armFence
    }

    /// `fenceWait` has passed since `.armFence` with no third `.
    mutating func fenceElapsed() -> Action {
        guard fenceArmed else { return .none }
        fenceArmed = false
        return .trigger
    }

    /// Any other key or a click breaks the sequence.
    mutating func reset() -> Action {
        downAt = nil
        lastTapAt = Self.never
        let wasArmed = fenceArmed
        fenceArmed = false
        return wasArmed ? .cancelFence : .none
    }
}
