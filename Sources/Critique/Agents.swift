import AppKit
import SwiftTerm
import SwiftUI

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

    /// Letting the agent work unattended is Critique's choice. To narrow it for Claude
    /// Code, swap `--dangerously-skip-permissions` for `--permission-mode acceptEdits`
    /// plus `--allowedTools` listing the commands you trust: a terminal session then
    /// stops to ask about the rest, and a headless one turns them down.
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
        arguments(model: model).joined(separator: " ")
    }

    /// The command as separate arguments. An empty model means the agent's own default.
    func arguments(model: String) -> [String] {
        let extra = model.isEmpty || !hasModels ? [] : ["--model", model]
        return [executable] + flags + extra
    }
}

/// How Critique runs Claude Code: headless, over JSON with a session per project,
/// or in a terminal, as one real session at the top of your projects folder.
/// Codex and Gemini only run in a terminal.
enum AgentMode: String {
    case headless, terminal
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

/// The coding agent Critique runs for you. Headless (the default for Claude Code),
/// it's one `claude -p` session per project, each in its project's folder and
/// started by the first critique for it, with no terminal at all; Show opens a
/// transcript. In Terminal mode it's one real session at the top of your projects
/// folder (~/repos), in a terminal that lives inside Critique with no window until
/// you ask for one; closing that window leaves it running. Either way, critiques go
/// straight to it.
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

    // MARK: Mode

    private static let modeKey = "agent.mode"

    /// Headless unless you switch it off. Changing it stops what's running, since the
    /// other mode is a different kind of process, and starts over in the new one.
    @Published var mode: AgentMode = AgentMode(rawValue: UserDefaults.standard.string(forKey: Agents.modeKey) ?? "") ?? .headless {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            guard mode != oldValue, !running.isEmpty else { return }
            running.forEach(drop)
            start()
        }
    }

    /// What actually runs: only Claude Code can go headless.
    var isHeadless: Bool { defaultKind == .claude && mode == .headless }

    // MARK: The main agent

    /// The folder the main agent runs in: where you keep your projects, so it can
    /// work in any of them. ~/repos unless you pick another.
    @Published private(set) var root: URL = {
        if let saved = UserDefaults.standard.string(forKey: "agent.root"), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("repos")
    }()

    /// Whether you picked the projects folder yourself. Headless sessions get it as
    /// an extra directory (`--add-dir`) only then, since the default is just a guess.
    private var rootChosen: Bool { !(UserDefaults.standard.string(forKey: "agent.root") ?? "").isEmpty }

    private var rootProject: FeedbackRecord.ProjectRecord {
        FeedbackRecord.ProjectRecord(name: root.lastPathComponent, path: root.path, branch: nil, remote: nil)
    }

    /// Terminal mode's one agent. It sits at `root` and works on whichever project a critique is for.
    @Published private(set) var terminalAgent: Agent?

    /// Headless sessions by project path. Each starts with the first critique for its project.
    @Published private(set) var sessions: [String: Agent] = [:]

    /// The agent your next critique goes to: the terminal agent, or the headless
    /// session for the project you picked (failing that, the newest one).
    var master: Agent? {
        if let terminalAgent { return terminalAgent }
        if let active = Projects.shared.active, let session = sessions[active.path] { return session }
        return sessions.values.max { $0.startedAt < $1.startedAt }
    }

    /// Everything running, oldest first.
    var running: [Agent] {
        (terminalAgent.map { [$0] } ?? []) + sessions.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// The agent critiques for `project` go to: the terminal agent, or in headless
    /// mode the project's own session (the root folder's, for a critique with no project).
    func agent(for project: FeedbackRecord.ProjectRecord?) -> Agent? {
        terminalAgent ?? sessions[project?.path ?? root.path]
    }

    /// Picks a new root. A running agent restarts there.
    func setRoot(_ url: URL) {
        root = url
        UserDefaults.standard.set(url.path, forKey: "agent.root")
        guard !running.isEmpty else { return }
        running.forEach(drop)
        start()
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

    /// Starts the terminal agent if Start Automatically is on and it isn't running yet.
    /// Headless sessions wait for a critique instead, since that says which project to run in.
    @discardableResult
    func ensureRunning() -> Agent? {
        if let master { return master }
        guard autoStart, installed.contains(defaultKind), !isHeadless else { return nil }
        return start()
    }

    /// The agent that takes a critique for `project`, started if Start Automatically is on.
    @discardableResult
    func ensureRunning(for project: FeedbackRecord.ProjectRecord?) -> Agent? {
        if let agent = agent(for: project) { return agent }
        guard autoStart, installed.contains(defaultKind) else { return nil }
        return isHeadless ? start(session: project ?? rootProject) : start()
    }

    /// Start: the terminal agent, or in headless mode a session for the project you
    /// picked (the root folder with none).
    @discardableResult
    func start(kind: AgentKind? = nil) -> Agent {
        let kind = kind ?? defaultKind
        if kind == .claude, mode == .headless { return start(session: Projects.shared.active ?? rootProject) }
        if let terminalAgent { return terminalAgent }
        let agent = Agent(project: rootProject, kind: kind, model: defaultModel(for: kind), mode: .terminal)
        agent.onExit = { [weak self, weak agent] in
            guard let self, let agent, self.terminalAgent === agent else { return }
            self.terminalAgent = nil
            agent.closeWindow()
        }
        terminalAgent = agent
        agent.launch()
        startPolling()
        return agent
    }

    @discardableResult
    private func start(session project: FeedbackRecord.ProjectRecord) -> Agent {
        if let session = sessions[project.path] { return session }
        let addDir = rootChosen && project.path != root.path ? root : nil
        let agent = Agent(project: project, kind: .claude, model: defaultModel(for: .claude), mode: .headless,
                          addDir: addDir, resume: Self.savedSessions[project.path])
        agent.onExit = { [weak self, weak agent] in
            guard let self, let agent, self.sessions[project.path] === agent else { return }
            self.sessions[project.path] = nil
            agent.closeWindow()
        }
        agent.onSession = { id in Self.saveSession(id, for: project.path) }
        sessions[project.path] = agent
        agent.launch()
        startPolling()
        return agent
    }

    /// Headless session ids by project path, so a session picks up where it left
    /// off after Critique restarts.
    private static var savedSessions: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "agent.sessions") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "agent.sessions") }
    }

    private static func saveSession(_ id: String?, for path: String) {
        var saved = savedSessions
        saved[path] = id
        savedSessions = saved
    }

    func stop() {
        master?.stop()
    }

    func stopAll() { running.forEach { $0.stop() } }

    /// Stops the agent and starts the other kind in its place. It starts fresh;
    /// it doesn't carry over the old conversation.
    func switchKind(to kind: AgentKind) {
        defaultKind = kind
        guard let master, master.kind != kind else { return }
        running.forEach(drop)
        start(kind: kind)
    }

    /// Lets go of an agent that's being replaced: it stops on its own time and no
    /// longer counts as running.
    private func drop(_ agent: Agent) {
        if terminalAgent === agent { terminalAgent = nil }
        if sessions[agent.project.path] === agent { sessions[agent.project.path] = nil }
        agent.onExit = { [weak agent] in agent?.closeWindow() }
        agent.stop()
    }

    /// Hands a critique to the agent for its project. A terminal agent gets one line
    /// typed in, as if you did, with the project named; a headless session gets the
    /// feedback itself as the message, since nothing has to fit on a prompt line.
    /// Returns false when nothing is running.
    func send(_ line: String, for record: FeedbackRecord, in dir: URL) -> Bool {
        guard let agent = agent(for: record.project) else { return false }
        if agent.mode == .headless {
            agent.type(line + "\n\n" + record.markdown(in: dir))
        } else {
            var forAgent = line
            if let project = record.project { forAgent += " It's for \(project.name), in \(project.path)." }
            agent.type(forAgent)
        }
        return true
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { // scheduled here, so it fires on the main run loop
                guard let self else { return }
                let running = self.running
                running.forEach { $0.refreshStatus() }
                if running.isEmpty { self.timer?.invalidate(); self.timer = nil }
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

    /// One turn: from a prompt going in to the agent being done with it.
    struct Turn {
        let started: Date
        let finished: Date
    }

    enum TurnEvent {
        case started(Date)
        case finished(Turn)
        /// The agent stopped; nothing more is coming.
        case exited
    }

    let id = UUID()
    let project: FeedbackRecord.ProjectRecord
    let kind: AgentKind
    let mode: AgentMode
    /// The model it's running, as an alias like "opus". Empty means the agent's default.
    @Published private(set) var model: String
    let startedAt = Date()
    @Published private(set) var status: Status = .starting
    /// What it's working on: Claude Code's terminal title, or a headless session's current tool.
    @Published private(set) var task: String?
    /// The last critique sent to this agent.
    @Published private(set) var lastSent: Date?
    /// Claude Code's id for the conversation, once it says.
    @Published private(set) var sessionID: String?
    /// What a headless session has been told, said and done.
    @Published private(set) var transcript: [TranscriptEntry] = []

    var onExit: (() -> Void)?
    /// A headless session's id to save for `--resume`, or nil when the saved one turned out to be gone.
    var onSession: ((String?) -> Void)?

    /// Terminal mode's terminal. Headless agents have none.
    let terminal: LocalProcessTerminalView?
    private var headless: HeadlessSession?
    private var hooks: HookWatcher?
    /// What Claude Code's hooks last said. Once there is one, it beats the screen.
    private var hookStatus: Status?
    private let addDir: URL?
    private var resume: String?
    private var sawInit = false
    private var retryFresh = false
    private var window: NSWindow?

    var shortName: String { project.name.split(separator: "/").last.map(String.init) ?? project.name }

    init(project: FeedbackRecord.ProjectRecord, kind: AgentKind, model: String = "", mode: AgentMode = .terminal,
         addDir: URL? = nil, resume: String? = nil) {
        self.project = project
        self.kind = kind
        self.model = model
        self.mode = mode
        self.addDir = addDir
        self.resume = resume
        terminal = mode == .terminal ? LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 620)) : nil
        super.init()
        terminal?.processDelegate = self
        terminal?.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func launch() {
        var env = ProcessInfo.processInfo.environment
        // If Critique itself was opened from a Claude Code session, don't pass that session's markers on.
        for key in ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_CHILD_SESSION",
                    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID",
                    "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET",
                    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SSE_PORT"] {
            env.removeValue(forKey: key)
        }
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        if mode == .headless { launchHeadless(env) } else { launchTerminal(env) }
    }

    private func launchTerminal(_ env: [String: String]) {
        var args = kind.arguments(model: model)
        if kind == .claude {
            // Claude Code says what it's doing through hooks (AgentHooks); its screen is only a fallback.
            if let (settings, events) = try? AgentHooks.prepare() {
                args += ["--settings", settings.path]
                hooks = HookWatcher(file: events) { [weak self] event in self?.handle(event) }
            } else {
                log("couldn't set up Claude Code hooks; reading its screen instead")
            }
        }
        // A login, interactive shell finds `claude` wherever your shell config puts it.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = "exec " + args.map(HeadlessSession.quoted).joined(separator: " ")
        var env = env
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        terminal?.startProcess(executable: shell, args: ["-l", "-i", "-c", command],
                               environment: env.map { "\($0.key)=\($0.value)" },
                               execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                               currentDirectory: project.path)
        log("\(kind.name) started in \(project.path)")
    }

    private func launchHeadless(_ env: [String: String]) {
        var args = kind.arguments(model: model)
        args += ["-p", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose"]
        if let addDir { args += ["--add-dir", addDir.path] }
        if let resume { args += ["--resume", resume] }
        let session = HeadlessSession(arguments: args, directory: project.path, environment: env) { [weak self] event in
            self?.handle(event)
        }
        session.onExit = { [weak self] code, stderr in self?.headlessExited(code, stderr: stderr) }
        do {
            try session.start()
            headless = session
            log("\(kind.name) started headless in \(project.path)\(resume.map { ", resuming \($0)" } ?? "")")
        } catch {
            log("couldn't start \(kind.name) headless: \(error.localizedDescription)")
            note("Couldn't start Claude Code: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in self?.exited() }
        }
    }

    func stop() {
        terminal?.terminate()
        headless?.stop()
    }

    /// Switches the running session's model with Claude Code's /model command,
    /// so the conversation carries on. A headless session takes it as a message.
    func switchModel(to model: String) {
        guard kind == .claude, model != self.model else { return }
        let command = "/model \(model.isEmpty ? "default" : model)"
        if let headless {
            headless.send(command)
            note(command)
        } else {
            terminal?.send(txt: command)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.terminal?.send(txt: "\r") }
        }
        self.model = model
    }

    /// Critiques that arrived before the agent was ready to take them.
    @Published private var waiting: [String] = []
    private var readyChecks = 0

    var hasWaiting: Bool { !waiting.isEmpty }

    /// Hands a critique to the agent: typed into the terminal, or sent as a message
    /// to a headless session. If it's still starting up (or asking you something),
    /// it waits and goes in as soon as the agent is ready.
    func type(_ line: String) {
        lastSent = Date()
        if mode == .headless {
            guard sawInit else { waiting.append(line); return }
            deliver(line)
            return
        }
        guard status == .ready || status == .working else {
            waiting.append(line)
            return
        }
        press(line)
    }

    private func press(_ line: String) {
        terminal?.send(txt: line)
        // Claude Code treats a fast Return as part of a paste, so press it a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.terminal?.send(txt: "\r")
        }
    }

    /// Headless: the message goes in now, and a turn is on. Claude Code queues it if
    /// it's still busy with the last one.
    private func deliver(_ line: String) {
        headless?.send(line)
        append(.you, line)
        beginTurn()
        status = .working
    }

    // MARK: Window

    /// A terminal agent's terminal, or a headless session's transcript.
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "\(shortName) · \(kind.name)"
            window.contentView = terminal ?? NSHostingView(rootView: TranscriptView(agent: self))
            window.center()
            window.setFrameAutosaveName("CritiqueAgent-\(project.path)")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let terminal { window?.makeFirstResponder(terminal) }
    }

    func closeWindow() {
        window?.close()
    }

    // MARK: Turns

    private var listeners: [UUID: AsyncStream<TurnEvent>.Continuation] = [:]
    /// When the turn in progress began, if one is.
    private(set) var currentTurnStart: Date?
    private(set) var lastTurn: Turn?

    /// A live feed of this agent's turns, from Claude Code's hooks (terminal), its
    /// stream (headless), or the screen (other agents). Each caller gets its own
    /// stream, buffered so nothing is missed.
    func turns() -> AsyncStream<TurnEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnEvent.self)
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[id] = nil }
        }
        return stream
    }

    /// Waits for the agent to finish a turn that began after `since`: the one the
    /// critique you just sent starts. False if none begins within `startTimeout`,
    /// or the agent stops first.
    func turnFinished(after since: Date, startTimeout: TimeInterval = 180) async -> Bool {
        if let last = lastTurn, last.started >= since { return true }
        let events = turns()
        let startedAlready = currentTurnStart.map { $0 >= since } ?? false
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                var started = startedAlready
                for await event in events {
                    switch event {
                    case .started(let at): if at >= since { started = true }
                    case .finished(let turn): if started || turn.started >= since { return true }
                    case .exited: return false
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(startTimeout))
                return nil
            }
            var finished = false
            while let next = await group.next() {
                if let next { finished = next; break }
                // The clock ran out: keep waiting only if a turn did start by now.
                let underway = await MainActor.run { (self.currentTurnStart ?? self.lastTurn?.started).map { $0 >= since } ?? false }
                if !underway { break }
            }
            group.cancelAll()
            return finished
        }
    }

    private func emit(_ event: TurnEvent) {
        for listener in listeners.values { listener.yield(event) }
        if case .exited = event { listeners.values.forEach { $0.finish() } }
    }

    private func beginTurn() {
        let now = Date()
        currentTurnStart = now
        emit(.started(now))
    }

    private func endTurn() {
        guard let started = currentTurnStart else { return }
        let turn = Turn(started: started, finished: Date())
        currentTurnStart = nil
        lastTurn = turn
        emit(.finished(turn))
    }

    private func exited() {
        hooks?.stop()
        hooks = nil
        emit(.exited)
        onExit?()
    }

    // MARK: Status

    /// What the terminal title says, when the agent uses it for status. Claude Code
    /// starts its title with ✳ when idle and an animated glyph (◐ ◑, or a braille
    /// spinner in older versions) while working.
    private var titleBusy: Bool?
    private var titleIdleChecks = 0

    /// Claude Code's working line, like "✻ Running… (3s · ↓ 7 tokens)". Once it's
    /// done, that line turns into "✻ Cogitated for 14s", with no "…".
    private static let spinnerLine = try! NSRegularExpression(pattern: "^\\s*[·✢✳✶✻✽*]\\s+\\S[^\\n]*…", options: .anchorsMatchLines)

    /// Works out what a terminal agent is doing, once a second. Claude Code's hooks
    /// say outright; other agents, and Claude Code before its first hook event, are
    /// read off the screen. A headless session's stream drives its status directly.
    func refreshStatus() {
        guard mode == .terminal else { return }
        var next = hookStatus ?? scrapedStatus()
        if hookStatus == .working {
            // Stop hooks don't fire when a turn is cut short with esc. The title going
            // idle (✳) and staying there is the tell that it's really done.
            titleIdleChecks = titleBusy == false ? titleIdleChecks + 1 : 0
            if titleIdleChecks >= 3 {
                hookStatus = .ready
                next = .ready
                endTurn()
            }
        } else {
            titleIdleChecks = 0
        }
        if next != status { status = next }

        // Off the screen, a turn starts when it looks busy and ends once it has looked ready a while.
        readyChecks = next == .ready ? readyChecks + 1 : 0
        if hookStatus == nil {
            if next == .working, currentTurnStart == nil { beginTurn() }
            if readyChecks == 6 { endTurn() }
        }

        // Hand over waiting critiques once it has looked ready for two checks in a row,
        // so the prompt is really taking input.
        if readyChecks >= 2, !waiting.isEmpty {
            let lines = waiting
            waiting.removeAll()
            for (i, line) in lines.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) { [weak self] in self?.press(line) }
            }
        }
    }

    /// Asking you something wins, then working, then ready.
    private func scrapedStatus() -> Status {
        guard let term = terminal?.getTerminal() else { return status }
        var screen = ""
        for row in 0..<term.rows {
            if let line = term.getLine(row: row) { screen += line.translateToString(trimRight: true) + "\n" }
        }
        // The title is the surest sign. Only fall back to the spinner line without it.
        let spinning = titleBusy == nil && Self.spinnerLine.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) != nil
        if screen.contains("Enter to confirm") || screen.contains("Yes, I accept") {
            return .needsYou
        } else if titleBusy == true || spinning
                    || screen.localizedCaseInsensitiveContains("esc to interrupt")
                    || screen.localizedCaseInsensitiveContains("ctrl+b to run in background") {
            return .working
        } else if titleBusy == false || screen.contains("? for shortcuts") || screen.contains("❯") || screen.contains(">") {
            return .ready
        } else {
            return status == .starting ? .starting : .ready
        }
    }

    /// Claude Code's hooks, in a terminal session. See AgentHooks for what fires when.
    private func handle(_ event: HookEvent) {
        if let id = event.sessionID, id != sessionID { sessionID = id }
        switch event.name {
        case "SessionStart":
            // After auto-compaction it carries straight on; otherwise it's at the prompt.
            if event.source != "compact" { hookStatus = .ready }
        case "UserPromptSubmit":
            hookStatus = .working
            beginTurn()
        case "Stop":
            hookStatus = .ready
            endTurn()
        case "Notification":
            switch event.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
                hookStatus = .needsYou
            case "idle_prompt":
                // Idle for a minute mid-turn means it asked you something. After a Stop
                // it just means you haven't typed anything, which is fine.
                if hookStatus == .working { hookStatus = .needsYou }
            default:
                break
            }
        case "PostToolUse":
            // You answered, and it's going again.
            if hookStatus == .needsYou { hookStatus = .working }
        default:
            break
        }
        if let hookStatus, hookStatus != status { status = hookStatus }
    }

    /// A headless session's stream.
    private func handle(_ event: HeadlessSession.Event) {
        switch event {
        case .started(let id, let model):
            if id != sessionID {
                sessionID = id
                onSession?(id)
            }
            guard !sawInit else { return }
            sawInit = true
            status = .ready
            note("Session \(id.prefix(8)) · \(model ?? "default model")\(resume == nil ? "" : " · resumed")")
            let lines = waiting
            waiting.removeAll()
            lines.forEach(deliver)
        case .assistantText(let text):
            append(.agent, text)
        case .toolUse(let name, let detail):
            task = detail.map { "\(name) \($0)" } ?? name
            append(.tool, task ?? name)
        case .result(let isError, let text, let errors):
            if resume != nil, !sawInit, errors.contains(where: { $0.contains("No conversation found") }) {
                // The saved session is gone (cleared or purged). Start fresh once this one exits.
                resume = nil
                onSession?(nil)
                retryFresh = true
                return
            }
            if isError {
                note("Error: \((errors + [text ?? ""]).filter { !$0.isEmpty }.joined(separator: " · "))")
            }
            task = nil
            status = .ready
            endTurn()
        }
    }

    private func headlessExited(_ code: Int32, stderr: String) {
        headless = nil
        if retryFresh {
            retryFresh = false
            log("Headless \(kind.name) in \(project.path): saved session gone, starting fresh")
            launch()
            return
        }
        log("Headless \(kind.name) in \(project.path) exited (\(code))\(stderr.isEmpty ? "" : ": \(stderr)")")
        if code != 0, !stderr.isEmpty { note("Claude Code exited: \(stderr)") }
        exited()
    }

    private func append(_ role: TranscriptEntry.Role, _ text: String) {
        transcript.append(TranscriptEntry(role: role, text: text))
        if transcript.count > 1000 { transcript.removeFirst(200) }
    }

    private func note(_ text: String) { append(.note, text) }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Claude Code puts ✳ in front of the title when idle, and a spinner while it
        // works. Keep that as status, and just the words as the task.
        let glyph = title.prefix { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        let words = title.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        MainActor.assumeIsolated { // SwiftTerm calls its delegate on the main queue
            if kind == .claude { titleBusy = glyph.isEmpty ? nil : glyph != "✳" }
            task = words.isEmpty || words == kind.name || words == "Claude Code" || words.lowercased() == kind.executable ? nil : words
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            log("Agent in \(self.project.path) exited (\(exitCode.map(String.init) ?? "?"))")
            self.exited()
        }
    }
}
