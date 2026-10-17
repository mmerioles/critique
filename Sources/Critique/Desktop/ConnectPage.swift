import AppKit
import SwiftUI

/// How your coding agent gets your critiques (MCP), plus the one setting that matters.
struct ConnectPage: View {
    @AppStorage("pasteIntoAgent") private var pasteIntoAgent = true
    @State private var copied = false

    private var command: String {
        let exe = Bundle.main.executableURL?.path ?? "/Applications/Critique.app/Contents/MacOS/Critique"
        return "claude mcp add critique -- \"\(exe)\" mcp"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your agent").font(.system(size: 26, weight: .medium))
                Text("Critique talks to coding agents over MCP. Run this once in your terminal:")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 8)

            HStack {
                Text(command)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))

            VStack(alignment: .leading, spacing: 12) {
                Text("Then ask your agent").font(.system(size: 12, weight: .medium)).kerning(1.2).foregroundStyle(Theme.secondary)
                example("“Check my latest critique and fix it.”")
                example("“Wait for my critique, then fix it.” It starts as soon as you send.")
            }

            Toggle(isOn: $pasteIntoAgent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically send to Claude Code").font(.system(size: 14))
                    Text("Types one line into Claude Code and presses Enter for you.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.red)

            Spacer()
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 32)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func example(_ text: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.red).frame(width: 2, height: 18)
            Text(text).font(.system(size: 14))
        }
    }
}
