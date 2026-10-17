import AppKit

// `UXFlow mcp`    → run as an MCP server so coding agents can pull feedback.
// `UXFlow latest` → print the newest feedback as Markdown.
// no arguments    → run the menu bar app.
switch CommandLine.arguments.dropFirst().first {
case "mcp":
    MCPServer.run()
case "latest":
    if let dir = Inbox.items().first, let record = Inbox.load(dir) {
        print(record.markdown(in: dir))
    } else {
        print("No feedback yet. Double-tap right Option to record some.")
    }
default:
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
