import Foundation

/// How much of your Claude plan you've used: the rolling 5-hour window and the week.
///
/// Reads the same numbers as Claude Code's /usage, using the sign-in Claude Code
/// already saved in your keychain. Nothing is stored; the token never leaves this
/// request to api.anthropic.com.
@MainActor
final class ClaudeUsage: ObservableObject {
    static let shared = ClaudeUsage()

    struct Window: Equatable {
        /// 0–100
        let percent: Double
        let resetsAt: Date?
    }

    enum State: Equatable {
        case unknown
        case loaded(fiveHour: Window?, weekly: Window?)
        case signedOut
        case failed
    }

    @Published private(set) var state: State = .unknown
    private(set) var updatedAt: Date?
    private var loading = false

    /// Refreshes unless it did so in the last 30 seconds.
    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, let updatedAt, Date().timeIntervalSince(updatedAt) < 30 { return }
        loading = true
        defer { loading = false }
        let next = await Self.fetch()
        updatedAt = Date()
        // Keep the last good numbers through a blip.
        if next == .failed, case .loaded = state { return }
        state = next
    }

    nonisolated private static func fetch() async -> State {
        guard let token = await Task.detached(priority: .utility, operation: { accessToken() }).value else { return .signedOut }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        // An expired token: Claude Code refreshes it the next time it runs.
        if http.statusCode == 401 || http.statusCode == 403 { return .signedOut }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
        return .loaded(fiveHour: window(json["five_hour"]), weekly: window(json["seven_day"]))
    }

    nonisolated private static func window(_ value: Any?) -> Window? {
        guard let dict = value as? [String: Any], let percent = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resets = (dict["resets_at"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return Window(percent: percent, resetsAt: resets)
    }

    /// Claude Code keeps its sign-in in the keychain on macOS, or in ~/.claude/.credentials.json.
    nonisolated static func accessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var data = Data()
        if (try? process.run()) != nil {
            data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 { data = Data() }
        }
        if data.isEmpty {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            data = (try? Data(contentsOf: file)) ?? Data()
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
