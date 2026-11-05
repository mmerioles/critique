import AppKit
import SwiftUI
import Synchronization

/// Claude Code with no terminal: `claude -p` kept running, with critiques going in
/// as JSON user messages on stdin and its stream-json output read back for what
/// it's doing. One of these runs per project, in that project's folder.
///
/// Flags, checked against `claude --help` (2.1.318) and a scripted run:
/// `-p --output-format stream-json --input-format stream-json --verbose` keeps one
/// process taking turn after turn; `--resume <id>` picks a session back up (a gone
/// id answers with a `result` of subtype `error_during_execution` and exits);
/// `--add-dir` opens the projects folder; `/model <alias>` sent as a message
/// switches the model in place.
///
/// Unchecked: `buffer` is only touched by stdout's readability handler (one call at a
/// time), `stderrTail` is behind a lock, and Process and Pipe are thread-safe.
final class HeadlessSession: @unchecked Sendable {
    /// What the stream said, boiled down to what Critique shows and tracks.
    enum Event {
        /// `system`/`init`: the session is up. It comes again at the start of each turn.
        case started(sessionID: String, model: String?)
        case assistantText(String)
        case toolUse(name: String, detail: String?)
        /// `result`: the turn is over. `errors` is set when Claude Code couldn't run it at all.
        case result(isError: Bool, text: String?, errors: [String])
    }

    private let process = Process()
    private let input = Pipe()
    private var buffer = Data()
    private let stderrTail = Mutex<[String]>([])
    private let directory: String
    private let onEvent: @MainActor @Sendable (Event) -> Void
    var onExit: (@MainActor @Sendable (Int32, String) -> Void)?

    /// Writing to a pipe whose reader has died would otherwise kill Critique.
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(arguments: [String], directory: String, environment: [String: String],
         onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        _ = Self.ignoreBrokenPipes
        self.directory = directory
        self.onEvent = onEvent
        // A login shell finds `claude` wherever your shell config puts it.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "exec " + arguments.map(Self.quoted).joined(separator: " ")]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardInput = input
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.take(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            self.stderrTail.withLock { $0 = Array(($0 + lines).suffix(5)) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            let tail = self?.stderrTail.withLock { $0.joined(separator: " · ") } ?? ""
            Task { @MainActor [weak self] in self?.onExit?(status, tail) }
        }
    }

    func start() throws { try process.run() }

    var isRunning: Bool { process.isRunning }

    /// Single-quotes an argument for the shell when it needs it. The same spelling
    /// works in sh, bash, zsh and fish.
    static func quoted(_ argument: String) -> String {
        let plain = argument.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_./=:+,@".unicodeScalars.contains($0) }
        return plain && !argument.isEmpty ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Sends one user message. Claude Code takes it now, or queues it if a turn is running.
    func send(_ text: String) {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard process.isRunning, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    /// SIGTERM: Claude Code drops the turn in progress and exits.
    func stop() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    private func take(_ data: Data) {
        buffer.append(data)
        var events: [Event] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            // Anything that isn't JSON (a login shell's greeting, say) is skipped.
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            events += parse(json)
        }
        guard !events.isEmpty else { return }
        let onEvent = onEvent
        Task { @MainActor [events] in events.forEach(onEvent) }
    }

    private func parse(_ json: [String: Any]) -> [Event] {
        switch json["type"] as? String {
        case "system":
            guard json["subtype"] as? String == "init", let id = json["session_id"] as? String else { return [] }
            return [.started(sessionID: id, model: json["model"] as? String)]
        case "assistant":
            // Subagents' messages carry their parent tool id; the transcript shows the main conversation.
            guard json["parent_tool_use_id"] as? String == nil,
                  let blocks = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : .assistantText(text)
                case "tool_use":
                    guard let name = block["name"] as? String else { return nil }
                    return .toolUse(name: name, detail: detail(of: block["input"] as? [String: Any]))
                default:
                    return nil
                }
            }
        case "result":
            return [.result(isError: json["is_error"] as? Bool ?? false, text: json["result"] as? String,
                            errors: json["errors"] as? [String] ?? [])]
        default:
            return []
        }
    }

    /// The one thing worth showing about a tool call: the file, command, or description.
    private func detail(of input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["file_path", "path", "command", "pattern", "description", "url", "query", "prompt"] {
            guard var value = input[key] as? String, !value.isEmpty else { continue }
            value = value.replacingOccurrences(of: directory + "/", with: "")
                .replacingOccurrences(of: "\n", with: " ")
            return value.count > 90 ? String(value.prefix(90)) + "…" : value
        }
        return nil
    }
}

/// One line of a headless session's transcript.
struct TranscriptEntry: Identifiable {
    enum Role { case you, agent, tool, note }
    let id = UUID()
    let time = Date()
    let role: Role
    let text: String
}

/// What a headless session has been told, said and done, as a plain log.
struct TranscriptView: View {
    @ObservedObject var agent: Agent

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(agent.status.label).font(.system(size: 12, weight: .medium))
                if let task = agent.task {
                    Text(task).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                Text(agent.project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.border)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if agent.transcript.isEmpty {
                            Text("Nothing yet. Send a critique and it shows up here.")
                                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        }
                        ForEach(agent.transcript) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if let last = agent.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: agent.transcript.count) { _, _ in
                    if let last = agent.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Theme.panel)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
    }

    private func row(_ entry: TranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label(entry.role))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint(entry.role))
                .frame(width: 48, alignment: .trailing)
            Text(entry.text)
                .font(.system(size: 12, design: entry.role == .tool ? .monospaced : .default))
                .foregroundStyle(entry.role == .note ? Theme.secondary : Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ role: TranscriptEntry.Role) -> String {
        switch role {
        case .you: "You"
        case .agent: "Claude"
        case .tool: "Tool"
        case .note: "Note"
        }
    }

    private func tint(_ role: TranscriptEntry.Role) -> Color {
        switch role {
        case .you: Theme.red
        case .agent: Theme.ink
        case .tool, .note: Theme.tertiary
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
}
