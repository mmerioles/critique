import Foundation

/// How Critique learns what a terminal Claude Code session is doing without
/// reading its screen: Claude Code hooks. Critique launches it with
/// `--settings <file>` whose hooks append each event's JSON to a file, and
/// watches that file. The `--settings` file is layered over the user's own
/// settings (keys left out keep their values, and hook lists merge), so hooks
/// in ~/.claude/settings.json still run.
///
/// Verified against Claude Code 2.1.318: SessionStart, UserPromptSubmit, Stop,
/// Notification and PostToolUse all fire with `hook_event_name` in their stdin
/// JSON; Notification carries `notification_type` (permission_prompt,
/// idle_prompt, …); SessionStart carries `source` (startup, resume, clear, compact).
enum AgentHooks {
    /// Where the settings and events files live: ~/.critique/agent/.
    static var dir: URL { Inbox.root.deletingLastPathComponent().appendingPathComponent("agent") }

    /// Writes the settings file for one launch and an empty events file for it to
    /// fill, and returns both. Only one terminal session runs at a time, so the
    /// names are fixed and the events file starts over with each launch.
    static func prepare() throws -> (settings: URL, events: URL) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let events = dir.appendingPathComponent("events.jsonl")
        let settings = dir.appendingPathComponent("hooks-settings.json")
        try Data().write(to: events)

        let quoted = "'" + events.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // The whole event, one line each. Claude Code's JSON ends in a newline already;
        // the echo makes sure of it, and the reader skips the blank line it adds.
        let record = "/bin/cat >> \(quoted); /bin/echo >> \(quoted)"
        // Tool calls are frequent and their input can be big, so just note that one happened.
        let marker = "/bin/cat > /dev/null; /bin/echo '{\"hook_event_name\":\"PostToolUse\"}' >> \(quoted)"
        func hook(_ command: String) -> [[String: Any]] { [["hooks": [["type": "command", "command": command]]]] }
        let json: [String: Any] = ["hooks": [
            "SessionStart": hook(record),
            "UserPromptSubmit": hook(record),
            "Stop": hook(record),
            "Notification": hook(record),
            "PostToolUse": hook(marker),
        ]]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: settings)
        return (settings, events)
    }
}

/// One hook event, as Claude Code sent it.
struct HookEvent {
    let name: String
    let sessionID: String?
    /// For Notification: permission_prompt, idle_prompt, and so on.
    let notificationType: String?
    /// For SessionStart: startup, resume, clear or compact.
    let source: String?

    init?(json: [String: Any]) {
        guard let name = json["hook_event_name"] as? String else { return nil }
        self.name = name
        sessionID = json["session_id"] as? String
        notificationType = json["notification_type"] as? String
        source = json["source"] as? String
    }
}

/// Watches the events file and hands each new line to `onEvent` on the main thread.
/// Unchecked: `partial` is only touched on the source's own serial queue.
final class HookWatcher: @unchecked Sendable {
    private let handle: FileHandle
    private let source: DispatchSourceFileSystemObject
    private var partial = Data()
    private let onEvent: @MainActor @Sendable (HookEvent) -> Void

    init?(file: URL, onEvent: @escaping @MainActor @Sendable (HookEvent) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        self.handle = handle
        self.onEvent = onEvent
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle.fileDescriptor,
                                                           eventMask: [.write, .extend],
                                                           queue: DispatchQueue(label: "critique.agent.hooks"))
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    /// Reads whatever was appended since last time. The handle keeps its place.
    private func drain() {
        partial.append(handle.readDataToEndOfFile())
        var events: [HookEvent] = []
        while let end = partial.firstIndex(of: 10) {
            let line = partial[partial.startIndex..<end]
            partial.removeSubrange(partial.startIndex...end)
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = HookEvent(json: json) else { continue }
            events.append(event)
        }
        guard !events.isEmpty else { return }
        let onEvent = onEvent
        Task { @MainActor [events] in events.forEach(onEvent) }
    }

    func stop() {
        source.cancel()
    }
}
