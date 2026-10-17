import AppKit

/// After you send feedback, puts it straight into your coding agent's prompt
/// (e.g. Claude Code in your terminal) — without pressing Enter. You review and hit ⏎.
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

    /// Brings your agent's app forward and pastes the clipboard (the feedback),
    /// followed by a one-line instruction. Calls back with the app's name, or nil
    /// if it couldn't (then the feedback is still on the clipboard).
    func deliver(instruction: String, completion: @escaping (String?) -> Void) {
        guard isEnabled, AXIsProcessTrusted(),
              let app = lastAgentApp, !app.isTerminated, let url = app.bundleURL else { return completion(nil) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        app.activate()

        waitUntilFrontmost(app, tries: 15) { ready in
            // Never type into the wrong app.
            guard ready else { return completion(nil) }
            Self.press(9, flags: .maskCommand) // ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Self.type(" " + instruction)
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

    nonisolated private static func isAgentApp(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(agentApps.contains) ?? false
    }

    private static func press(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
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
