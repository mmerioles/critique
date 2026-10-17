import AppKit

/// After you send feedback, types a one-line pointer to it into Claude Code's
/// prompt and presses Enter, so Claude Code starts on it right away.
///
/// Safety: it only types into a window whose title shows Claude Code is running
/// (Claude Code puts ✳ or a spinner in the terminal title), and only ever a single
/// line, so it can never run anything in a plain shell.
@MainActor
final class AgentHandoff {
    /// Apps where coding agents usually live. The one you used most recently wins.
    nonisolated private static let agentApps: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
    ]

    private static let enabledKey = "pasteIntoAgent"
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var lastAgentApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        let workspace = NSWorkspace.shared
        lastAgentApp = [workspace.frontmostApplication].compactMap { $0 }.first(where: Self.isAgentApp)
            ?? workspace.runningApplications.first(where: Self.isAgentApp)
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isAgentApp(app) else { return }
            MainActor.assumeIsolated { self?.lastAgentApp = app }
        }
    }

    /// Brings your agent's app forward and types `line` into its prompt. Calls back
    /// with the app's name, or nil if Claude Code wasn't found in focus.
    func deliver(line: String, completion: @escaping (String?) -> Void) {
        guard isEnabled, AXIsProcessTrusted(), Feature.accessibility.isOn,
              let app = lastAgentApp, !app.isTerminated, let url = app.bundleURL else { return completion(nil) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        app.activate()

        waitUntilFrontmost(app, tries: 15) { ready in
            // Never type into the wrong app or a plain shell.
            guard ready, Self.showsClaudeCode(app) else { return completion(nil) }
            Self.type(line.replacingOccurrences(of: "\n", with: " "))
            // Give the terminal a moment to take in the text before submitting it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                Self.pressReturn()
                completion(app.localizedName)
            }
        }
    }

    private func waitUntilFrontmost(_ app: NSRunningApplication, tries: Int, then: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { then(true) } // let its window take focus
            return
        }
        guard tries > 0 else { return then(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilFrontmost(app, tries: tries - 1, then: then)
        }
    }

    /// Claude Code sets the terminal title to "✳ <task>" when idle and a braille
    /// spinner while working.
    private static func showsClaudeCode(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?, title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String else { return false }
        if text.contains("✳") || text.localizedCaseInsensitiveContains("claude") { return true }
        return text.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
    }

    nonisolated private static func isAgentApp(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(agentApps.contains) ?? false
    }

    private static func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    /// Types text as if from the keyboard (works with any keyboard layout).
    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
        }
    }
}
