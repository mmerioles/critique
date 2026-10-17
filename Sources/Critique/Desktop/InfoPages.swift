import AVFoundation
import AppKit
import Speech
import SwiftUI

/// Shared layout for the simple pages: a title, a subtitle, then content.
struct PageScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 26, weight: .medium))
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 8)
                content
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A bordered list of rows, like the critiques list.
struct RowList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Keys and what gets captured.
struct GuidePage: View {
    var body: some View {
        PageScaffold(title: "Guide", subtitle: "Everything Critique does, on one page.") {
            section("Keys")
            RowList {
                row(keys: ["right ⌥", "right ⌥"], "Start a critique, and send it")
                Divider().overlay(Theme.border)
                row(keys: ["hold `"], "Draw on the screen — this takes a screenshot")
                Divider().overlay(Theme.border)
                row(keys: ["esc"], "Cancel")
                Divider().overlay(Theme.border)
                row(keys: ["⌃⌥Space"], "Backup for the double-tap")
            }

            section("What your agent gets")
            RowList {
                row(icon: "waveform", "Your words, transcribed on your Mac")
                Divider().overlay(Theme.border)
                row(icon: "pencil.tip", "A whole-screen screenshot for each drawing")
                Divider().overlay(Theme.border)
                row(icon: "play.rectangle", "A recording of your screen and voice")
                Divider().overlay(Theme.border)
                row(icon: "cursorarrow.click", "Buttons and links you clicked or hovered")
            }

            section("Tips")
            VStack(alignment: .leading, spacing: 10) {
                tip("Say “this” while you draw — your words and the drawing are linked.")
                tip("Keep Claude Code as the active terminal tab so Critique can type into it.")
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 12, weight: .medium)).kerning(1.2).foregroundStyle(Theme.secondary)
    }

    private func row(keys: [String] = [], icon: String? = nil, _ text: String) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(Theme.secondary).frame(width: 20)
                }
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
            .frame(width: 150, alignment: .leading)
            Text(text).font(.system(size: 14))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.red).frame(width: 2, height: 18)
            Text(text).font(.system(size: 14))
        }
    }
}

/// Live status of each macOS permission, with a button to fix any that are off.
struct PermissionsPage: View {
    private struct Permission: Identifiable {
        let name: String
        let why: String
        let pane: String
        let isOn: () -> Bool
        var id: String { name }
    }

    private let permissions: [Permission] = [
        Permission(name: "Screen Recording", why: "See your screen and take screenshots", pane: "Privacy_ScreenCapture",
                   isOn: { CGPreflightScreenCaptureAccess() }),
        Permission(name: "Microphone", why: "Hear what you say", pane: "Privacy_Microphone",
                   isOn: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }),
        Permission(name: "Speech Recognition", why: "Turn your voice into text, on your Mac", pane: "Privacy_SpeechRecognition",
                   isOn: { SFSpeechRecognizer.authorizationStatus() == .authorized }),
        Permission(name: "Input Monitoring", why: "Notice the right ⌥ double-tap", pane: "Privacy_ListenEvent",
                   isOn: { CGPreflightListenEventAccess() }),
        Permission(name: "Accessibility", why: "Know which button or link you're on, and type into Claude Code", pane: "Privacy_Accessibility",
                   isOn: { AXIsProcessTrusted() }),
    ]

    @State private var status: [String: Bool] = [:]
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        PageScaffold(title: "Permissions", subtitle: "Critique needs these to work. Everything stays on your Mac.") {
            RowList {
                ForEach(Array(permissions.enumerated()), id: \.element.id) { index, permission in
                    if index > 0 { Divider().overlay(Theme.border) }
                    HStack(spacing: 14) {
                        Image(systemName: status[permission.name] == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(status[permission.name] == true ? Color.green : Theme.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.name).font(.system(size: 14, weight: .medium))
                            Text(permission.why).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        if status[permission.name] != true {
                            Button("Allow") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.pane)")!)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
            Text("Allowed something but it still shows as off? Quit and reopen Critique.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
        .onAppear(perform: check)
        .onReceive(refresh) { _ in check() }
    }

    private func check() {
        status = Dictionary(uniqueKeysWithValues: permissions.map { ($0.name, $0.isOn()) })
    }
}
