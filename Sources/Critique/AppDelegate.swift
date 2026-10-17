import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var critique: CritiqueController!
    private var statusItem: NSStatusItem!
    private var store: CritiqueStore!
    private var window: MainWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        critique = CritiqueController()
        store = CritiqueStore()
        window = MainWindow(store: store, handoff: critique.handoff)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Critique")

        let menu = NSMenu()
        menu.addItem(item("Open Critique", #selector(openWindow)))
        menu.addItem(item("Give Feedback  (double-tap right ⌥)", #selector(giveFeedback)))
        menu.addItem(.separator())
        let paste = item("Send to Claude Code Automatically", #selector(togglePaste))
        paste.state = critique.handoff.isEnabled ? .on : .off
        menu.addItem(paste)
        menu.addItem(item("Copy Latest Feedback", #selector(copyLatest)))
        menu.addItem(item("Open Feedback Inbox", #selector(openInbox)))
        menu.addItem(item("Connect Claude Code (copy command)", #selector(copyMCPCommand)))
        menu.addItem(.separator())
        menu.addItem(item("Screen Recording Settings…", #selector(openPrivacy)))
        menu.addItem(item("Input Monitoring Settings…", #selector(openInputMonitoring)))
        menu.addItem(item("Accessibility Settings…", #selector(openAccessibility)))
        menu.addItem(item("Quit Critique", #selector(quit)))
        statusItem.menu = menu

        window.show()
        Task { await Transcriber.prepare() } // get the speech model ready before the first critique
        if !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
        // Lets Critique box the exact button/text you point at.
        if !ElementLocator.isTrusted { ElementLocator.requestTrust() }
        critique.notice(CGPreflightListenEventAccess()
                    ? "Ready. Double-tap right Option anywhere to give feedback."
                    : "Allow Input Monitoring for Critique to use double-tap right Option. ⌃⌥Space works meanwhile.",
                    seconds: 4)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func giveFeedback() { critique.toggle() }

    @objc private func openWindow() { window.show() }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    @objc private func togglePaste(_ sender: NSMenuItem) {
        critique.handoff.isEnabled.toggle()
        sender.state = critique.handoff.isEnabled ? .on : .off
    }

    @objc private func copyLatest() {
        guard let dir = Inbox.items().first, let record = Inbox.load(dir) else {
            critique.notice("No feedback yet.", seconds: 2)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.markdown(in: dir), forType: .string)
        critique.notice("Latest feedback copied — paste it into your agent.", seconds: 2)
    }

    @objc private func openInbox() {
        try? FileManager.default.createDirectory(at: Inbox.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Inbox.root)
    }

    @objc private func copyMCPCommand() {
        let exe = Bundle.main.executableURL?.path ?? "/Applications/Critique.app/Contents/MacOS/Critique"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude mcp add critique -- \"\(exe)\" mcp", forType: .string)
        critique.notice("Copied. Paste it in your terminal to give Claude Code your feedback.", seconds: 3)
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
