import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var flow: FlowController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        flow = FlowController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.and.pencil", accessibilityDescription: "UX Flow")

        let menu = NSMenu()
        menu.addItem(item("Give Feedback  (double-tap right ⌥)", #selector(giveFeedback)))
        menu.addItem(.separator())
        let paste = item("Paste Into Agent After Sending", #selector(togglePaste))
        paste.state = flow.handoff.isEnabled ? .on : .off
        menu.addItem(paste)
        menu.addItem(item("Copy Latest Feedback", #selector(copyLatest)))
        menu.addItem(item("Open Feedback Inbox", #selector(openInbox)))
        menu.addItem(item("Connect Claude Code (copy command)", #selector(copyMCPCommand)))
        menu.addItem(.separator())
        menu.addItem(item("Screen Recording Settings…", #selector(openPrivacy)))
        menu.addItem(item("Input Monitoring Settings…", #selector(openInputMonitoring)))
        menu.addItem(item("Accessibility Settings…", #selector(openAccessibility)))
        menu.addItem(item("Quit UX Flow", #selector(quit)))
        statusItem.menu = menu

        if !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
        // Lets UX Flow box the exact button/text you point at.
        if !ElementLocator.isTrusted { ElementLocator.requestTrust() }
        flow.notice(CGPreflightListenEventAccess()
                    ? "Ready. Double-tap right Option anywhere to give feedback."
                    : "Allow Input Monitoring for UX Flow to use double-tap right Option. ⌃⌥Space works meanwhile.",
                    seconds: 4)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func giveFeedback() { flow.toggle() }

    @objc private func togglePaste(_ sender: NSMenuItem) {
        flow.handoff.isEnabled.toggle()
        sender.state = flow.handoff.isEnabled ? .on : .off
    }

    @objc private func copyLatest() {
        guard let dir = Inbox.items().first, let record = Inbox.load(dir) else {
            flow.notice("No feedback yet.", seconds: 2)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.markdown(in: dir), forType: .string)
        flow.notice("Latest feedback copied — paste it into your agent.", seconds: 2)
    }

    @objc private func openInbox() {
        try? FileManager.default.createDirectory(at: Inbox.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Inbox.root)
    }

    @objc private func copyMCPCommand() {
        let exe = Bundle.main.executableURL?.path ?? "/Applications/UXFlow.app/Contents/MacOS/UXFlow"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude mcp add uxflow -- \"\(exe)\" mcp", forType: .string)
        flow.notice("Copied. Paste it in your terminal to give Claude Code your feedback.", seconds: 3)
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
