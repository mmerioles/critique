import AppKit
import ApplicationServices

/// Finds the UI element under the cursor (a button, link, image, piece of text…)
/// using macOS Accessibility — the same tech screen readers use. This is what lets
/// Critique draw a box around "this button" without you drawing anything.
enum ElementLocator {
    struct Element {
        /// Global coordinates, top-left origin.
        let frame: CGRect
        /// e.g. `button “Sign up”`
        let label: String
        let role: String
        /// Something you can click, type into, or open (button, link, menu item, field…).
        var isInteractive: Bool { ElementLocator.interactiveRoles.contains(role) }
    }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea", "AXSearchField", "AXSlider", "AXTab",
        "AXDisclosureTriangle", "AXIncrementor", "AXSwitch", "AXToggle", "AXColorWell", "AXDateField",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Chrome and Electron apps only build their accessibility tree when asked.
    static func wakeUp(_ pid: pid_t) {
        queue.async { enableWebAccessibility(pid) }
    }

    static func element(at point: CGPoint, maxArea: CGFloat) async -> Element? {
        guard isTrusted else { return nil }
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: find(at: point, maxArea: maxArea)) }
        }
    }

    /// What's inside an area (global, top-left origin): samples a grid of points
    /// and returns the distinct elements found, interactive ones first.
    static func elements(in rect: CGRect, maxArea: CGFloat) async -> [Element] {
        guard isTrusted, rect.width > 0, rect.height > 0 else { return [] }
        return await withCheckedContinuation { cont in
            queue.async {
                let cols = max(2, min(7, Int(rect.width / 40))), rows = max(2, min(7, Int(rect.height / 40)))
                var found: [Element] = []
                var seen = Set<String>()
                for r in 0..<rows {
                    for c in 0..<cols {
                        let p = CGPoint(x: rect.minX + rect.width * (CGFloat(c) + 0.5) / CGFloat(cols),
                                        y: rect.minY + rect.height * (CGFloat(r) + 0.5) / CGFloat(rows))
                        guard let element = find(at: p, maxArea: maxArea),
                              seen.insert("\(element.label)|\(Int(element.frame.minX))|\(Int(element.frame.minY))").inserted else { continue }
                        found.append(element)
                    }
                }
                let interactive = found.filter(\.isInteractive)
                cont.resume(returning: interactive + found.filter { !$0.isInteractive }.prefix(max(0, 6 - interactive.count)))
            }
        }
    }

    // MARK: - Private (runs on `queue`)

    private static let queue = DispatchQueue(label: "critique.accessibility")
    private static var awakened = Set<pid_t>()
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }()

    /// Hitting these means you're pointing at a page or window background.
    private static let stopRoles: Set<String> = ["AXWindow", "AXApplication", "AXWebArea", "AXDesktop", "AXMenuBar"]
    /// Layout-only wrappers that are never what you mean.
    private static let wrapperRoles: Set<String> = ["AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXUnknown", "AXSplitter"]
    /// Generic containers ("group", "article", "list"…) — too vague to box. When the
    /// cursor is on one of these, Critique shows a ring at the cursor instead.
    private static let genericRoles: Set<String> = ["AXGroup", "AXList", "AXSection", "AXGeneric", "AXLayoutItem",
                                                    "AXOutline", "AXTable", "AXBrowser", "AXGrid", "AXColumn",
                                                    "AXRow", "AXLandmarkMain", "AXDocument", "AXSheet", "AXDrawer"]
    /// If the thing under the cursor sits inside one of these, box the control instead (text inside a button → the button).
    private static let controlRoles: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton",
                                                    "AXPopUpButton", "AXMenuButton", "AXCell", "AXTab", "AXDisclosureTriangle"]

    private static func enableWebAccessibility(_ pid: pid_t) {
        guard !awakened.contains(pid) else { return }
        awakened.insert(pid)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func find(at point: CGPoint, maxArea: CGFloat) -> Element? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid != getpid() { enableWebAccessibility(pid) }
        if pid == getpid() { return nil }

        for _ in 0..<10 {
            let role = string(element, kAXRoleAttribute) ?? ""
            if stopRoles.contains(role) || genericRoles.contains(role) { return nil }
            if let f = frame(element), !wrapperRoles.contains(role) {
                if f.width * f.height > maxArea { return nil } // grew to a whole panel — too vague
                if f.width >= 14 && f.height >= 10 {
                    if let parent = parent(element), let parentRole = string(parent, kAXRoleAttribute),
                       controlRoles.contains(parentRole), let pf = frame(parent), pf.width * pf.height <= maxArea {
                        return Element(frame: pf, label: label(parent, role: parentRole), role: parentRole)
                    }
                    return Element(frame: f, label: label(element, role: role), role: role)
                }
            }
            guard let parent = parent(element) else { return nil }
            element = parent
        }
        return nil
    }

    private static func label(_ element: AXUIElement, role: String) -> String {
        let kind = string(element, kAXRoleDescriptionAttribute) ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
        let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .lazy.compactMap { string(element, $0) }
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } // one line
            .first { !$0.isEmpty }
        guard let text else { return kind }
        return "\(kind) “\(text.count > 80 ? text.prefix(80) + "…" : text)”"
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
