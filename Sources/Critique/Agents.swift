import AppKit
import SwiftTerm

/// The coding agents Critique can run. Each runs with its "don't ask me" flag.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, gemini

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        }
    }

    var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }

    var flags: [String] {
        switch self {
        case .claude: ["--dangerously-skip-permissions"]
        case .codex: ["--dangerously-bypass-approvals-and-sandbox"]
        case .gemini: ["--yolo"]
        }
    }

    var commandLine: String { ([executable] + flags).joined(separator: " ") }

    /// Only Claude Code has a model menu for now; the others keep their default.
    var hasModels: Bool { self == .claude }

    /// An empty model means the agent's own default.
    func commandLine(model: String) -> String {
        let extra = model.isEmpty || !hasModels ? [] : ["--model", model]
        return ([executable] + flags + extra).joined(separator: " ")
    }
}

struct AgentModel: Hashable, Identifiable {
    let id: String
    let name: String
}

/// The Claude models your account can use, newest first, and which one Claude Code
/// uses by default. Loaded with the sign-in Claude Code already saved, like usage.
@MainActor
final class ClaudeModels: ObservableObject {
    static let shared = ClaudeModels()

    /// Used until the live list loads, or if it can't.
    private static let fallback = [
        AgentModel(id: "opus", name: "Opus"), AgentModel(id: "sonnet", name: "Sonnet"),
        AgentModel(id: "haiku", name: "Haiku"), AgentModel(id: "fable", name: "Fable"),
    ]

    @Published private(set) var all: [AgentModel] = ClaudeModels.fallback
    /// The model setting in ~/.claude/settings.json, like "opus".
    @Published private(set) var configured: String?
    private var loaded = false

    /// The newest of each family (Opus, Sonnet, Haiku, Fable).
    var latest: [AgentModel] {
        var seen = Set<String>()
        let order = ["fable", "opus", "sonnet", "haiku"]
        return all.filter { seen.insert(Self.family($0.id)).inserted }
            .sorted { (order.firstIndex(of: Self.family($0.id)) ?? 9) < (order.firstIndex(of: Self.family($1.id)) ?? 9) }
    }

    var older: [AgentModel] {
        let top = Set(latest)
        return all.filter { !top.contains($0) }
    }

    /// What "default" actually runs, like "Opus 5.5".
    var defaultName: String? {
        guard let configured = configured?.lowercased(), !configured.isEmpty else { return nil }
        let base = configured.replacingOccurrences(of: "[1m]", with: "")
        if let exact = all.first(where: { $0.id == base }) { return exact.name }
        return all.first { Self.family($0.id) == base }?.name ?? base.capitalized
    }

    func name(_ id: String) -> String {
        if id.isEmpty { return defaultName.map { "\($0) (default)" } ?? "Default model" }
        return all.first { $0.id == id }?.name ?? id.capitalized
    }

    func load() async {
        configured = Self.readConfigured()
        guard !loaded else { return }
        if let models = await Self.fetch(), !models.isEmpty {
            all = models
            loaded = true
        }
    }

    /// "claude-opus-5-5" → "opus"
    nonisolated static func family(_ id: String) -> String {
        let parts = id.split(separator: "-")
        return parts.count > 1 && parts[0] == "claude" ? String(parts[1]) : id
    }

    nonisolated private static func readConfigured() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"], !env.isEmpty { return env }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["model"] as? String
    }

    nonisolated private static func fetch() async -> [AgentModel]? {
        guard let token = await Task.detached(priority: .utility, operation: { ClaudeUsage.accessToken() }).value else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["display_name"] as? String ?? id).replacingOccurrences(of: "Claude ", with: "")
            return AgentModel(id: id, name: name)
        }
    }
}

/// The coding agent Critique runs for you: one main agent at the top of your
/// projects folder (~/repos), working on whichever project a critique is for.
///
/// Each runs in its own terminal that lives inside Critique, with no window until
/// you ask for one. Show opens it as a regular Claude Code session you can type
/// into; closing that window leaves the agent running. Critiques for a project
/// with a running agent go straight to it.
@MainActor
final class Agents: ObservableObject {
    static let shared = Agents()

    /// Which agents are on your PATH. Until the check finishes, assume Claude Code is.
    @Published private(set) var installed: Set<AgentKind> = [.claude]

    private var timer: Timer?
    private static let kindKey = "agent.kind"

    /// The agent new sessions start with: whichever you picked last.
    @Published var defaultKind: AgentKind = AgentKind(rawValue: UserDefaults.standard.string(forKey: Agents.kindKey) ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(defaultKind.rawValue, forKey: Self.kindKey) }
    }

    /// The model new sessions of each agent start with, by agent.
    @Published private(set) var defaultModels: [AgentKind: String] = Dictionary(uniqueKeysWithValues:
        AgentKind.allCases.map { ($0, UserDefaults.standard.string(forKey: "agent.model.\($0.rawValue)") ?? "") })

    func defaultModel(for kind: AgentKind) -> String { defaultModels[kind] ?? "" }

    func setDefaultModel(_ model: String, for kind: AgentKind) {
        defaultModels[kind] = model
        UserDefaults.standard.set(model, forKey: "agent.model.\(kind.rawValue)")
    }

    private init() {
        Task { installed = await Self.findInstalled() }
    }

    /// Asks a login shell, so it finds agents wherever your shell config puts them.
    private static func findInstalled() async -> Set<AgentKind> {
        await Task.detached(priority: .utility) {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let names = AgentKind.allCases.map(\.executable).joined(separator: " ")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", "for c in \(names); do command -v $c >/dev/null 2>&1 && echo $c; done"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [.claude] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let found = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            let kinds = Set(AgentKind.allCases.filter { found.contains($0.executable) })
            return kinds.isEmpty ? [.claude] : kinds
        }.value
    }

    // MARK: The main agent

    /// The folder the main agent runs in: where you keep your projects, so it can
    /// work in any of them. ~/repos unless you pick another.
    @Published private(set) var root: URL = {
        if let saved = UserDefaults.standard.string(forKey: "agent.root"), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("repos")
    }()

    /// The one agent Critique runs. It sits at `root` and works on whichever project a critique is for.
    @Published private(set) var master: Agent?

    /// For places that just need to know whether anything is running.
    var running: [Agent] { master.map { [$0] } ?? [] }

    /// Picks a new root. A running agent restarts there.
    func setRoot(_ url: URL) {
        root = url
        UserDefaults.standard.set(url.path, forKey: "agent.root")
        if let master { restart(master, kind: master.kind) }
    }

    private static let autoStartKey = "agent.autoStart"

    /// Keep the agent running so critiques always have somewhere to go: it starts
    /// with Critique, and again whenever you start a critique. On unless you turn it off.
    @Published var autoStart: Bool = UserDefaults.standard.object(forKey: Agents.autoStartKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoStart, forKey: Self.autoStartKey)
            if autoStart { ensureRunning() }
        }
    }

    /// Starts the agent if Start Automatically is on and it isn't running yet.
    @discardableResult
    func ensureRunning() -> Agent? {
        if let master { return master }
        guard autoStart, installed.contains(defaultKind) else { return nil }
        return start()
    }

    @discardableResult
    func start(kind: AgentKind? = nil) -> Agent {
        if let master { return master }
        let kind = kind ?? defaultKind
        let place = FeedbackRecord.ProjectRecord(name: root.lastPathComponent, path: root.path, branch: nil, remote: nil)
        let agent = Agent(project: place, kind: kind, model: defaultModel(for: kind))
        agent.onExit = { [weak self, weak agent] in
            guard let self, let agent, self.master === agent else { return }
            self.master = nil
            agent.closeWindow()
        }
        master = agent
        agent.launch()
        startPolling()
        return agent
    }

    func stop() {
        master?.stop()
    }

    func stopAll() { stop() }

    /// Stops the agent and starts the other kind in its place. It starts fresh;
    /// it doesn't carry over the old conversation.
    func switchKind(to kind: AgentKind) {
        defaultKind = kind
        guard let master, master.kind != kind else { return }
        restart(master, kind: kind)
    }

    private func restart(_ agent: Agent, kind: AgentKind) {
        self.master = nil
        agent.onExit = { [weak agent] in agent?.closeWindow() }
        agent.stop()
        start(kind: kind)
    }

    /// Hands a critique to the main agent, as if you typed it and pressed Enter.
    /// Returns false when it isn't running.
    func send(_ line: String) -> Bool {
        guard let master else { return false }
        master.type(line)
        return true
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.master?.refreshStatus()
                if self.master == nil { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }
}

@MainActor
final class Agent: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    enum Status: Equatable {
        case starting, working, ready, needsYou
        var label: String {
            switch self {
            case .starting: "Starting"
            case .working: "Working"
            case .ready: "Ready"
            case .needsYou: "Needs you"
            }
        }
    }

    let id = UUID()
    let project: FeedbackRecord.ProjectRecord
    let kind: AgentKind
    /// The model it's running, as an alias like "opus". Empty means the agent's default.
    @Published private(set) var model: String
    let startedAt = Date()
    @Published private(set) var status: Status = .starting
    /// What Claude Code says it's working on (it puts this in the terminal title).
    @Published private(set) var task: String?
    /// The last critique sent to this agent.
    @Published private(set) var lastSent: Date?

    var onExit: (() -> Void)?
    let terminal: LocalProcessTerminalView
    private var window: NSWindow?

    var shortName: String { project.name.split(separator: "/").last.map(String.init) ?? project.name }

    init(project: FeedbackRecord.ProjectRecord, kind: AgentKind, model: String = "") {
        self.project = project
        self.kind = kind
        self.model = model
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 620))
        super.init()
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func launch() {
        // A login, interactive shell finds `claude` wherever your shell config puts it.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = "exec " + kind.commandLine(model: model)
        var env = ProcessInfo.processInfo.environment
        // If Critique itself was opened from a Claude Code session, don't pass that session's markers on.
        for key in ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_CHILD_SESSION",
                    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID",
                    "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET",
                    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SSE_PORT"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        terminal.startProcess(executable: shell, args: ["-l", "-i", "-c", command],
                              environment: env.map { "\($0.key)=\($0.value)" },
                              execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                              currentDirectory: project.path)
        log("\(kind.name) started in \(project.path)")
    }

    func stop() {
        terminal.terminate()
    }

    /// Switches the running session's model with Claude Code's /model command,
    /// so the conversation carries on.
    func switchModel(to model: String) {
        guard kind == .claude, model != self.model else { return }
        terminal.send(txt: "/model \(model.isEmpty ? "default" : model)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.terminal.send(txt: "\r") }
        self.model = model
    }

    /// Critiques that arrived before the agent was ready to take them.
    @Published private var waiting: [String] = []
    private var readyChecks = 0

    var hasWaiting: Bool { !waiting.isEmpty }

    /// Types a critique into the agent. If it's still starting up (or asking you
    /// something), it waits and goes in as soon as the agent is ready.
    func type(_ line: String) {
        lastSent = Date()
        guard status == .ready || status == .working else {
            waiting.append(line)
            return
        }
        press(line)
    }

    private func press(_ line: String) {
        terminal.send(txt: line)
        // Claude Code treats a fast Return as part of a paste, so press it a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.terminal.send(txt: "\r")
        }
    }

    // MARK: Window

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "\(shortName) · \(kind.name)"
            window.contentView = terminal
            window.center()
            window.setFrameAutosaveName("CritiqueAgent-\(project.path)")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminal)
    }

    func closeWindow() {
        window?.close()
    }

    // MARK: Status

    /// What the terminal title says, when the agent uses it for status. Claude Code
    /// starts its title with ✳ when idle and an animated glyph (◐ ◑, or a braille
    /// spinner in older versions) while working.
    private var titleBusy: Bool?

    /// Claude Code's working line, like "✻ Running… (3s · ↓ 7 tokens)". Once it's
    /// done, that line turns into "✻ Cogitated for 14s", with no "…".
    private static let spinnerLine = try! NSRegularExpression(pattern: "^\\s*[·✢✳✶✻✽*]\\s+\\S[^\\n]*…", options: .anchorsMatchLines)

    /// Works out what the agent is doing from its title and what's on its screen.
    /// Asking you something wins, then working, then ready.
    func refreshStatus() {
        let term = terminal.getTerminal()
        var screen = ""
        for row in 0..<term.rows {
            if let line = term.getLine(row: row) { screen += line.translateToString(trimRight: true) + "\n" }
        }
        // The title is the surest sign. Only fall back to the spinner line without it.
        let spinning = titleBusy == nil && Self.spinnerLine.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) != nil
        let next: Status
        if screen.contains("Enter to confirm") || screen.contains("Yes, I accept") {
            next = .needsYou
        } else if titleBusy == true || spinning
                    || screen.localizedCaseInsensitiveContains("esc to interrupt")
                    || screen.localizedCaseInsensitiveContains("ctrl+b to run in background") {
            next = .working
        } else if titleBusy == false || screen.contains("? for shortcuts") || screen.contains("❯") || screen.contains(">") {
            next = .ready
        } else {
            next = status == .starting ? .starting : .ready
        }
        if next != status { status = next }

        // Hand over waiting critiques once it has looked ready for two checks in a row,
        // so the prompt is really taking input.
        readyChecks = next == .ready ? readyChecks + 1 : 0
        if readyChecks >= 2, !waiting.isEmpty {
            let lines = waiting
            waiting.removeAll()
            for (i, line) in lines.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) { [weak self] in self?.press(line) }
            }
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Claude Code puts ✳ in front of the title when idle, and a spinner while it
        // works. Keep that as status, and just the words as the task.
        let glyph = title.prefix { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        let words = title.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        MainActor.assumeIsolated {
            if kind == .claude { titleBusy = glyph.isEmpty ? nil : glyph != "✳" }
            task = words.isEmpty || words == kind.name || words == "Claude Code" || words.lowercased() == kind.executable ? nil : words
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            log("Agent in \(self.project.path) exited (\(exitCode.map(String.init) ?? "?"))")
            self.onExit?()
        }
    }
}
