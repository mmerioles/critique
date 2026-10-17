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

/// Each permission with an on/off switch. Off grays the row and Critique stops
/// using it. On turns it back on and asks macOS for access if it's missing.
struct PermissionsPage: View {
    private struct Row: Identifiable {
        let feature: Feature
        let name: String
        let why: String
        let pane: String
        let granted: () -> Bool
        let request: () -> Void
        var id: String { name }
    }

    private let rows: [Row] = [
        Row(feature: .screen, name: "Screen Recording", why: "Record your screen and take screenshots when you draw",
            pane: "Privacy_ScreenCapture", granted: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() }),
        Row(feature: .voice, name: "Microphone & Speech", why: "Hear what you say and turn it into text, on your Mac",
            pane: "Privacy_Microphone",
            granted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && SFSpeechRecognizer.authorizationStatus() == .authorized },
            request: { Task { _ = await Dictation.authorize() } }),
        Row(feature: .doubleTap, name: "Input Monitoring", why: "Start and send with a right ⌥ double-tap (⌃⌥Space always works)",
            pane: "Privacy_ListenEvent", granted: { CGPreflightListenEventAccess() },
            request: { CGRequestListenEventAccess() }),
        Row(feature: .accessibility, name: "Accessibility", why: "Name the buttons you touch, and type into Claude Code for you",
            pane: "Privacy_Accessibility", granted: { AXIsProcessTrusted() },
            request: { ElementLocator.requestTrust() }),
    ]

    @State private var on: [Feature: Bool] = [:]
    @State private var granted: [Feature: Bool] = [:]
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        PageScaffold(title: "Permissions", subtitle: "Turn off anything you don't want Critique to use.") {
            RowList {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(Theme.border) }
                    permissionRow(row)
                }
            }
            Text("Switched on but still needs access? Allow Critique in System Settings, then quit and reopen it.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
        .onAppear(perform: check)
        .onReceive(refresh) { _ in check() }
    }

    private func permissionRow(_ row: Row) -> some View {
        let isOn = on[row.feature] ?? true
        let hasAccess = granted[row.feature] ?? false
        return HStack(spacing: 14) {
            Image(systemName: !isOn ? "circle.slash" : hasAccess ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(!isOn ? Theme.tertiary : hasAccess ? Color.green : Theme.red)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 14, weight: .medium))
                Text(isOn && !hasAccess ? "Needs access — click Allow" : row.why)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if isOn && !hasAccess {
                Button("Allow") { allow(row) }
            }
            Toggle("", isOn: Binding(get: { isOn }, set: { set(row, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.red)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .opacity(isOn ? 1 : 0.45) // off rows go gray
        .animation(.easeOut(duration: 0.15), value: isOn)
    }

    private func set(_ row: Row, _ value: Bool) {
        row.feature.set(value)
        on[row.feature] = value
        if value && !row.granted() { allow(row) }
    }

    private func allow(_ row: Row) {
        row.request()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(row.pane)")!)
    }

    private func check() {
        for row in rows {
            on[row.feature] = row.feature.isOn
            granted[row.feature] = row.granted()
        }
    }
}
