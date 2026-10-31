import AppKit
import SwiftUI

/// One main agent at the top of your projects folder. Start it, stop it, open its
/// terminal, and see what it's doing. Critiques for any project go to it.
struct AgentPage: View {
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var projects = Projects.shared
    @ObservedObject private var usage = ClaudeUsage.shared
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        PageScaffold(title: "Agent", subtitle: "Picks up your critiques and makes the changes.") {
            UsageMeters(state: usage.state, now: now)
        } content: {
            card
            if let master = agents.master {
                MasterStatus(agent: master, now: now)
            }
        }
        .onReceive(tick) { now = $0 }
        .task { if projects.local.isEmpty { await projects.refresh() } }
        // Check usage now and every minute while this page is open.
        .task {
            while !Task.isCancelled {
                await usage.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(Theme.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Works in").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text(agents.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                Button("Change…", action: pickRoot)
                    .help(agents.master == nil ? "Pick the folder that holds your projects" : "Restarts the agent in the new folder")
                Spacer()
                ModelMenu(agent: agents.master, kind: agents.master?.kind ?? agents.defaultKind)
                KindMenu(agent: agents.master)
                if let master = agents.master {
                    Button("Show") { master.show() }
                    Button("Stop") { agents.stop() }
                        .help(agents.autoStart ? "Stops it for now. It starts again with your next critique." : "Stop the agent")
                } else {
                    Button("Start") { agents.start() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.red)
                }
            }
            Divider().overlay(Theme.border)
            RepoMenu()
            Divider().overlay(Theme.border)
            HStack(spacing: 12) {
                Image(systemName: "bolt").foregroundStyle(Theme.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start automatically").font(.system(size: 13, weight: .medium))
                    Text("Runs when Critique opens and whenever you start a critique, so it's always ready to pick one up.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Toggle("Start automatically", isOn: $agents.autoStart)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .tint(Theme.red)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = agents.root
        panel.prompt = "Use Folder"
        panel.message = "Pick the folder that holds your projects. The agent starts here."
        if panel.runModal() == .OK, let url = panel.url { agents.setRoot(url) }
    }
}

/// Which repo your critiques are for, so the agent knows where to make the changes.
private struct RepoMenu: View {
    @ObservedObject private var projects = Projects.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Critiques for").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Menu {
                    item(nil, "No project")
                    if !projects.local.isEmpty { Divider() }
                    ForEach(projects.local) { item($0, $0.name) }
                } label: {
                    HStack(spacing: 4) {
                        Text(projects.active?.name ?? "No project").font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick the repo your critiques are for")
            }
            Spacer()
            if projects.active == nil {
                Text("Any agent can pick up your critiques.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else if let branch = projects.active?.branch {
                Text(branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func item(_ repo: Projects.Local?, _ name: String) -> some View {
        let on = repo?.path.path == projects.active?.path
        return Button {
            projects.select(repo)
        } label: {
            if on { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
        .disabled(on)
    }
}

/// What the running agent is doing right now.
private struct MasterStatus: View {
    @ObservedObject var agent: Agent
    let now: Date

    var body: some View {
        RowList {
            HStack(spacing: 14) {
                Circle().fill(color).frame(width: 8, height: 8).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(agent.kind.name).font(.system(size: 14, weight: .medium))
                        Text(agent.status.label).font(.system(size: 12)).foregroundStyle(color)
                    }
                    Text(detail)
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                Text(uptime).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private var detail: String {
        if agent.hasWaiting { return "Critique waiting until it's ready" }
        switch agent.status {
        case .working: return agent.task ?? "Working on it"
        case .needsYou: return "Asking you something. Click Show to answer."
        case .starting: return "Starting up"
        case .ready: return "Waiting for a critique"
        }
    }

    private var color: Color {
        switch agent.status {
        case .working: Theme.red
        case .needsYou: Color.orange
        case .ready: Color(red: 0.2, green: 0.6, blue: 0.35)
        case .starting: Theme.tertiary
        }
    }

    private var uptime: String {
        let s = max(0, Int(now.timeIntervalSince(agent.startedAt)))
        return s < 3600 ? String(format: "%d:%02d", s / 60, s % 60) : String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// Which agent runs, and a menu to change it. With no agent running, it picks the
/// one Start uses. Changing a running agent restarts it as the new one.
private struct KindMenu: View {
    let agent: Agent?
    @ObservedObject private var agents = Agents.shared
    @State private var confirming: AgentKind?

    private var current: AgentKind { agent?.kind ?? agents.defaultKind }

    var body: some View {
        Menu {
            ForEach(AgentKind.allCases) { kind in
                Button {
                    pick(kind)
                } label: {
                    if kind == current {
                        Label(kind.name, systemImage: "checkmark")
                    } else {
                        Text(agents.installed.contains(kind) ? kind.name : "\(kind.name) (not installed)")
                    }
                }
                .disabled(kind == current || !agents.installed.contains(kind))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                Text(current.name)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(agent == nil ? "Agent to start" : "Switch agent. Restarts it.")
        .confirmationDialog("Switch to \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Stop and Switch", role: .destructive) {
                if let kind = confirming { agents.switchKind(to: kind) }
                confirming = nil
            }
        } message: {
            Text("\(current.name) is in the middle of something. Switching stops it and starts \(confirming?.name ?? "") fresh.")
        }
    }

    private func pick(_ kind: AgentKind) {
        guard let agent else { agents.defaultKind = kind; return }
        if agent.status == .working { confirming = kind } else { agents.switchKind(to: kind) }
    }
}

/// The model an agent runs. With no agent, it picks the model Start uses.
/// For a running Claude Code agent, it switches in place with /model.
private struct ModelMenu: View {
    let agent: Agent?
    let kind: AgentKind
    @ObservedObject private var agents = Agents.shared

    var body: some View {
        if !kind.hasModels {
            EmptyView()
        } else if let agent {
            Running(agent: agent, kind: kind)
        } else {
            ModelPicker(current: agents.defaultModel(for: kind)) { agents.setDefaultModel($0, for: kind) }
        }
    }

    /// Watches the running agent so the label updates after a switch.
    private struct Running: View {
        @ObservedObject var agent: Agent
        let kind: AgentKind
        var body: some View {
            ModelPicker(current: agent.model) { model in
                agent.switchModel(to: model)
                Agents.shared.setDefaultModel(model, for: kind)
            }
        }
    }
}

/// Default (named, like "Opus 5.5 (default)"), the newest of each model, then older ones.
private struct ModelPicker: View {
    let current: String
    let pick: (String) -> Void
    @ObservedObject private var models = ClaudeModels.shared

    var body: some View {
        Menu {
            item("", models.name(""))
            Divider()
            ForEach(models.latest) { item($0.id, $0.name) }
            if !models.older.isEmpty {
                Menu("Older Models") {
                    ForEach(models.older) { item($0.id, $0.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(models.name(current))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model")
        .task { await models.load() }
    }

    private func item(_ id: String, _ name: String) -> some View {
        Button {
            pick(id)
        } label: {
            if id == current { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
        .disabled(id == current)
    }
}

/// Your Claude plan usage: the 5-hour window and the week.
private struct UsageMeters: View {
    let state: ClaudeUsage.State
    let now: Date

    var body: some View {
        switch state {
        case .unknown:
            EmptyView()
        case .signedOut:
            Text("Open Claude Code to see usage").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        case .failed:
            Text("Usage unavailable").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        case .loaded(let fiveHour, let weekly):
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                if let fiveHour { row("5-hour", fiveHour) }
                if let weekly { row("Weekly", weekly) }
            }
            .help("Claude plan usage, same as /usage in Claude Code")
        }
    }

    private func row(_ title: String, _ window: ClaudeUsage.Window) -> some View {
        GridRow {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(tint(window.percent))
                    .frame(width: 72 * min(1, max(0, window.percent / 100)))
            }
            .frame(width: 72, height: 5)
            Text("\(Int(window.percent.rounded()))%").font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
            Text(resets(window.resetsAt)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }

    private func tint(_ percent: Double) -> Color {
        percent >= 90 ? Theme.red : percent >= 70 ? Color.orange : Theme.secondary
    }

    private func resets(_ date: Date?) -> String {
        guard let date, date > now else { return "" }
        let left = date.timeIntervalSince(now)
        if left < 3600 { return "resets in \(max(1, Int(left / 60)))m" }
        if left < 86400 { return "resets \(date.formatted(date: .omitted, time: .shortened))" }
        return "resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}
