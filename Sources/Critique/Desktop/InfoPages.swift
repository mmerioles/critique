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
                keyRow([.option, .option], "Double-tap right option to start. Do it again to send.")
                Divider().overlay(Theme.border)
                keyRow([.backtick], "Hold and move the mouse to draw. Each drawing takes a screenshot.")
                Divider().overlay(Theme.border)
                keyRow([.escape], "Cancel")
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
                tip("Say “this” while you draw. Your words and the drawing are linked.")
                tip("Keep Claude Code as the active terminal tab so Critique can type into it.")
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 12, weight: .medium)).kerning(1.2).foregroundStyle(Theme.secondary)
    }

    private func keyRow(_ keys: [KeyboardKey], _ text: String) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { $0.element }
            }
            .frame(width: 210, alignment: .leading)
            Text(text).font(.system(size: 14))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func row(icon: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(Theme.secondary)
                .frame(width: 210, alignment: .leading)
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
        Row(feature: .doubleTap, name: "Input Monitoring", why: "Start and send with a right ⌥ double-tap",
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

/// Your account. There's no sign-in yet, so everything stays on this Mac.
struct AccountPage: View {
    @ObservedObject private var github = GitHubAccount.shared
    private var macName: String { (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()).capitalized }

    var body: some View {
        PageScaffold(title: "Account",
                     subtitle: github.profile == nil
                        ? "Sign in with GitHub. Your critiques still stay on this Mac."
                        : "Signed in with GitHub. Your critiques still stay on this Mac.") {
            RowList {
                header.padding(18)
                Divider().overlay(Theme.border)
                detail("Plan", "Free")
                Divider().overlay(Theme.border)
                detail("Email", github.profile.map { $0.email ?? "Private on GitHub" } ?? "Not signed in")
                Divider().overlay(Theme.border)
                detail("Critiques", "Saved on this Mac in ~/.critique")
            }
            if let error = github.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
        }
        .sheet(item: Binding(get: { github.pending.map(PendingBox.init) }, set: { if $0 == nil { github.cancelSignIn() } })) { box in
            DeviceCodeSheet(pending: box.pending) { github.cancelSignIn() }
        }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 14) {
            if let profile = github.profile {
                AsyncImage(url: profile.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initial(profile.name ?? profile.login)
                }
                .frame(width: 46, height: 46)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name ?? profile.login).font(.system(size: 15, weight: .medium))
                    HStack(spacing: 5) {
                        GitHubMark().frame(width: 12, height: 12)
                        Text("@\(profile.login)")
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Sign out") { github.signOut() }
            } else {
                initial(macName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(macName).font(.system(size: 15, weight: .medium))
                    Text("Local account on this Mac").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button { github.startSignIn() } label: {
                    HStack(spacing: 8) {
                        GitHubMark().frame(width: 16, height: 16)
                        Text("Sign in with GitHub").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.ink))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(github.isConfigured ? "" : "GitHub sign-in isn't set up in this build yet")
            }
        }
    }

    private func initial(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Circle().fill(Theme.ink))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).frame(width: 120, alignment: .leading)
            Text(value).font(.system(size: 14)).foregroundStyle(Theme.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private struct PendingBox: Identifiable {
        let pending: GitHubAccount.Pending
        var id: String { pending.userCode }
    }
}

/// Shows the one-time code while you approve the sign-in on github.com.
private struct DeviceCodeSheet: View {
    let pending: GitHubAccount.Pending
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            GitHubMark().frame(width: 34, height: 34)
            VStack(spacing: 6) {
                Text("Sign in with GitHub").font(.system(size: 18, weight: .semibold))
                Text("Paste this code on the GitHub page that just opened. It's already copied.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(pending.userCode)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .kerning(3)
                .textSelection(.enabled)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to approve").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 10) {
                Button("Cancel", action: cancel)
                Button("Open GitHub") { NSWorkspace.shared.open(pending.verificationURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 380)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
        // The window is always light, so keep the sheet light even in dark mode.
        .presentationBackground(Theme.panel)
        .preferredColorScheme(.light)
    }
}

/// GitHub's mark, drawn from its SVG so it stays crisp and takes the text color.
struct GitHubMark: View {
    private static let image: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}
