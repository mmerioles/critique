import Foundation
import Synchronization

/// Claude Code's sign-in, and the two things Critique reads with it: plan usage
/// (the meters on the Agent page) and the model list (the model menu).
///
/// Unofficial. Both endpoints are the ones Claude Code itself calls, with the OAuth
/// token it saves and a beta header; neither is documented, and either may change or
/// go away without notice:
///
///     GET https://api.anthropic.com/api/oauth/usage      anthropic-beta: oauth-2025-04-20
///     GET https://api.anthropic.com/v1/models?limit=100  the same, plus anthropic-version
///
/// So nothing here may break anything else. The token is read once per launch, off the
/// main thread and with a timeout (a keychain call can hang). `usage()` and `models()`
/// return nil on any failure (no token, timeout, non-200, bad JSON) and say why in the
/// log once per launch per kind of failure, never to the user. Callers treat nil as
/// "hide it": the Agent page shows no meters, and the model menu keeps its built-in list.
/// When the endpoints break for good, hide the feature: drop UsageMeters from AgentPage
/// and the fetch from ClaudeModels.load, then delete this file.
///
/// The token is never logged. It leaves memory only in the Authorization header of these
/// two requests to api.anthropic.com.
actor ClaudeAccount {
    static let shared = ClaudeAccount()

    /// How much of one window of the plan is used.
    struct Window: Equatable, Sendable {
        /// 0–100
        let percent: Double
        let resetsAt: Date?
    }

    /// The same numbers as Claude Code's /usage: the rolling 5-hour window and the week.
    struct Usage: Equatable, Sendable {
        let fiveHour: Window?
        let weekly: Window?
    }

    /// This launch's one keychain read, shared by everyone who asks.
    private var tokenRead: Task<String?, Never>?
    /// Kinds of failure already logged this launch.
    private var logged: Set<String> = []

    /// What Claude Code's /usage shows, or nil when it can't be read right now.
    func usage() async -> Usage? {
        guard let data = await get("https://api.anthropic.com/api/oauth/usage") else { return nil }
        guard let usage = Self.parseUsage(data) else {
            note("usage json", "the usage reply isn't in the shape Critique expects; hiding the meters")
            return nil
        }
        return usage
    }

    /// The models the account can use, as the API lists them, or nil when the list can't be read right now.
    func models() async -> [AgentModel]? {
        guard let data = await get("https://api.anthropic.com/v1/models?limit=100", versioned: true) else { return nil }
        guard let models = Self.parseModels(data), !models.isEmpty else {
            note("models json", "the model list isn't in the shape Critique expects; keeping the built-in one")
            return nil
        }
        return models
    }

    // MARK: Parsing

    /// `{"five_hour": {"utilization": 12.5, "resets_at": "…"}, "seven_day": {…}}`. Nil when neither window is there.
    static func parseUsage(_ data: Data) -> Usage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let usage = Usage(fiveHour: window(json["five_hour"]), weekly: window(json["seven_day"]))
        return usage.fiveHour == nil && usage.weekly == nil ? nil : usage
    }

    private static func window(_ value: Any?) -> Window? {
        guard let dict = value as? [String: Any], let percent = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resets = (dict["resets_at"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return Window(percent: percent, resetsAt: resets)
    }

    /// `{"data": [{"id": "claude-opus-4-1", "display_name": "Claude Opus 4.1"}, …]}`; names lose their "Claude " prefix.
    static func parseModels(_ data: Data) -> [AgentModel]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["display_name"] as? String ?? id).replacingOccurrences(of: "Claude ", with: "")
            return AgentModel(id: id, name: name)
        }
    }

    /// The access token in what Claude Code saves (its keychain item or ~/.claude/.credentials.json).
    static func token(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // MARK: The request

    /// GETs one endpoint with the token. Nil, with one log line per kind of trouble, when anything goes wrong.
    private func get(_ url: String, versioned: Bool = false) async -> Data? {
        guard let token = await token() else { return nil }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if versioned { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        request.timeoutInterval = 15
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            note("network", "couldn't reach api.anthropic.com: \(error.localizedDescription)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 401 or 403 is an expired token; Claude Code refreshes it the next time it runs.
            note("status \(status)", "api.anthropic.com answered \(status) for \(request.url?.path ?? url)")
            return nil
        }
        return data
    }

    private func note(_ kind: String, _ message: String) {
        guard logged.insert(kind).inserted else { return }
        log("claude: \(message)")
    }

    // MARK: The token

    /// Read once per launch; everyone waits on the same read.
    private func token() async -> String? {
        if let tokenRead { return await tokenRead.value }
        let read = Task.detached(priority: .utility) { Self.readToken(timeout: 5) }
        tokenRead = read
        return await read.value
    }

    /// Claude Code keeps its sign-in in the keychain on macOS (asked through `security`,
    /// which is killed after `timeout` so a locked or stuck keychain can't hang this),
    /// or in ~/.claude/.credentials.json. Runs once a launch, so it logs for itself.
    private static func readToken(timeout: TimeInterval) -> String? {
        var data = Data()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let output = Mutex(Data())
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                let read = out.fileHandleForReading.readDataToEndOfFile()
                output.withLock { $0 = read }
                done.signal()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                log("claude: the keychain didn't answer in \(Int(timeout)) s; trying ~/.claude/.credentials.json")
            } else {
                process.waitUntilExit()
                if process.terminationStatus == 0 { data = output.withLock { $0 } }
            }
        }
        if data.isEmpty {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            data = (try? Data(contentsOf: file)) ?? Data()
        }
        guard let token = token(in: data) else {
            log("claude: no Claude Code sign-in found; usage and the live model list stay hidden until the next launch")
            return nil
        }
        return token
    }
}

/// The usage meters on the Agent page, refreshed while it's open and hidden whenever
/// ClaudeAccount can't read them.
@MainActor
final class ClaudeUsage: ObservableObject {
    static let shared = ClaudeUsage()

    /// Nil until the first read, and whenever usage can't be read.
    @Published private(set) var usage: ClaudeAccount.Usage?
    private var updatedAt: Date?
    private var loading = false

    /// Refreshes unless it did so in the last 30 seconds.
    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, let updatedAt, Date().timeIntervalSince(updatedAt) < 30 { return }
        loading = true
        defer { loading = false }
        usage = await ClaudeAccount.shared.usage()
        updatedAt = Date()
    }
}
