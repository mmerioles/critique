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
        // Phone critiques (Mobile page) go to the agent the same way desktop ones do.
        Mobile.shared.deliver = { [weak critique] result in critique?.finishSending(result) }
        Mobile.shared.notice = { [weak critique] text in critique?.notice(text, seconds: 3.5) }
        Mobile.shared.startWatching()
        Updater.shared.notice = { [weak critique] text in critique?.notice(text, seconds: 3.5) }
        // The browser extension connects here to add DOM details to drawings on web pages.
        DOMCapture.shared.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Critique")

        let menu = NSMenu()
        menu.addItem(Updater.shared.updateItem) // "Update to 0.x.y…", hidden until there is one
        menu.addItem(item("Open Critique", #selector(openWindow)))
        menu.addItem(item("Give Feedback  (double-tap `)", #selector(giveFeedback)))
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
        menu.addItem(.separator())
        menu.addItem(Updater.shared.checkItem)
        menu.addItem(item("Quit Critique", #selector(quit)))
        statusItem.menu = menu

        window.show()
        // Clear out recordings left behind by crashes, and old ones past their keep-for limit.
        Retention.start()
        // The agent runs from the start, so your first critique has somewhere to go.
        Agents.shared.ensureRunning()
        Task { await Transcriber.prepare() } // get the speech model ready before the first critique
        Updater.shared.start() // looks for a newer release after a short delay, then daily
        if !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
        // Lets Critique box the exact button/text you point at.
        if !ElementLocator.isTrusted { ElementLocator.requestTrust() }
        critique.notice(CGPreflightListenEventAccess()
                    ? "Ready. Double-tap ` anywhere to give feedback."
                    : "Allow Input Monitoring for Critique to use the ` double-tap. ⌃⌥Space works meanwhile.",
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
    /// critique:// links (like "Return to Critique" on the sign-in page) bring the window forward.
    /// Agents run inside Critique, so quitting stops them. Check first.
    func applicationWillTerminate(_ notification: Notification) {
        // the phone mirror's adb process and port forward go with us
        PhoneMirror.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = Agents.shared.running.count
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Stop the running agent and quit?" : "Stop \(count) running agents and quit?"
        alert.informativeText = "Claude Code runs inside Critique, so it stops when Critique quits."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Agents.shared.stopAll()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "critique" }) else { return }
        window.show()
    }

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
