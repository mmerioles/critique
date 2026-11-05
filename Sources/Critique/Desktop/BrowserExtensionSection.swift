import AppKit
import SwiftUI

/// Whether the browser extension is talking to Critique, and how to load it. Sits on the Connect page.
struct BrowserExtensionSection: View {
    @ObservedObject private var dom = DOMCapture.shared
    @State private var copied = false
    private let folder = DOMCapture.extensionFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browser extension").font(.system(size: 12, weight: .medium)).kerning(1.2).foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                Circle().fill(dom.isConnected ? Color.green : Theme.tertiary).frame(width: 8, height: 8)
                Text(dom.isConnected ? "Connected to \(dom.browsers.joined(separator: ", "))" : "Not connected")
                    .font(.system(size: 14))
            }
            Text("On web pages, your agent also gets each element's CSS selector, test id and React/Vue component. Chrome, Arc, Brave, Edge and Firefox.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open chrome://extensions, turn on Developer mode, click Load unpacked and pick this folder:")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(folder?.path ?? "browser-extension/ in Critique's source (github.com/mmerioles/critique)")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                if let folder {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(folder.path, forType: .string)
                        copied = true
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
        }
    }
}
