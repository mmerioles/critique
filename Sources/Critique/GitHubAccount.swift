import AppKit
import Security

/// Sign in with GitHub, without a server.
///
/// Uses GitHub's device flow (the same one the `gh` CLI uses): Critique shows a
/// short code, you approve it on github.com, and Critique gets a token. The token
/// stays in your Keychain; your name, username, email and avatar are shown on
/// the Account page.
///
/// Needs the Client ID of a GitHub OAuth app with "Enable Device Flow" checked,
/// set as `GitHubClientID` in Info.plist. Client IDs are public; there's no secret.
@MainActor
final class GitHubAccount: ObservableObject {
    static let shared = GitHubAccount()

    struct Profile: Codable, Equatable {
        let login: String
        let name: String?
        let email: String?
        let avatarURL: URL?
    }

    /// Shown while you approve the sign-in on github.com.
    struct Pending: Equatable {
        let userCode: String
        let verificationURL: URL
    }

    @Published private(set) var profile: Profile?
    @Published private(set) var pending: Pending?
    @Published private(set) var error: String?

    private var signIn: Task<Void, Never>?
    private static let profileKey = "github.profile"
    nonisolated private static let keychainService = "dev.critique.github"

    static var clientID: String? {
        let id = (Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String)?
            .trimmingCharacters(in: .whitespaces)
        return id?.isEmpty == false ? id : nil
    }

    var isConfigured: Bool { Self.clientID != nil }

    /// The token, read from the keychain once and kept in memory. The keychain is
    /// only ever touched off the main thread: a keychain call can stall for a long
    /// time, and on the main thread that freezes the whole app.
    private var token: String?
    private var tokenRead = false
    /// Your repos, fetched once per launch (Refresh on the Repos page fetches again).
    @Published private(set) var cachedRepos: [Repo]?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.profileKey) {
            profile = try? JSONDecoder().decode(Profile.self, from: data)
        }
        // Make sure the saved sign-in still has its token, without blocking launch.
        Task { if await currentToken() == nil { profile = nil } }
    }

    private var tokenLoad: Task<String?, Never>?

    private func currentToken() async -> String? {
        if tokenRead { return token }
        // Everyone asking at once shares one keychain read.
        let load = tokenLoad ?? Task.detached(priority: .userInitiated) { Self.readToken() }
        tokenLoad = load
        let value = await load.value
        if !tokenRead { token = value; tokenRead = true }
        return token
    }

    // MARK: Sign in and out

    func startSignIn() {
        guard let clientID = Self.clientID else {
            error = "GitHub sign-in isn't set up in this build yet."
            return
        }
        signIn?.cancel()
        error = nil
        signIn = Task { [weak self] in
            do {
                let code = try await Self.requestDeviceCode(clientID: clientID)
                let pending = Pending(userCode: code.user_code,
                                      verificationURL: URL(string: code.verification_uri) ?? URL(string: "https://github.com/login/device")!)
                self?.pending = pending
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.user_code, forType: .string)
                NSWorkspace.shared.open(pending.verificationURL)

                let token = try await Self.waitForToken(clientID: clientID, code: code)
                let profile = try await Self.fetchProfile(token: token)
                self?.token = token
                self?.tokenRead = true
                await Task.detached { Self.saveToken(token) }.value
                UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: Self.profileKey)
                self?.profile = profile
                self?.pending = nil
                NSApp.activate()
            } catch is CancellationError {
                self?.pending = nil
            } catch {
                self?.pending = nil
                self?.error = error.localizedDescription
                log("GitHub sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelSignIn() {
        signIn?.cancel()
        signIn = nil
        pending = nil
    }

    func signOut() {
        token = nil
        tokenRead = true
        cachedRepos = nil
        Task.detached { Self.deleteToken() }
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        profile = nil
    }

    // MARK: Repos

    struct Repo: Decodable, Identifiable, Equatable {
        let full_name: String
        let name: String
        let html_url: String
        let clone_url: String
        let `private`: Bool
        let pushed_at: Date?
        let description: String?
        var id: String { full_name }
    }

    /// Your repos on GitHub, most recently pushed first.
    func repos(refresh: Bool = false) async throws -> [Repo] {
        if !refresh, let cachedRepos { return cachedRepos }
        guard let token = await currentToken() else { return [] }
        var request = URLRequest(url: URL(string: "https://api.github.com/user/repos?sort=pushed&per_page=50")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure(message: "Couldn't load your GitHub repos. Try again in a moment.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let repos = try decoder.decode([Repo].self, from: data)
        cachedRepos = repos
        return repos
    }

    // MARK: New repos

    /// Whether the saved sign-in may create repos. Sign-ins from before Critique
    /// could create repos only have read access; signing in again upgrades them.
    func canCreateRepos() async -> Bool {
        guard let (_, http) = try? await api("GET", "/user") else { return false }
        let scopes = (http.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return scopes.contains("repo") || scopes.contains("public_repo")
    }

    /// Why a repo name can't be used, or nil if GitHub would accept it as typed.
    /// GitHub allows letters, digits, `-`, `_` and `.`, up to 100 characters.
    nonisolated static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "" }
        if name.count > 100 { return "Names can be up to 100 characters." }
        if name == "." || name == ".." { return "That name is reserved." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use only letters, numbers, - _ and ."
        }
        return nil
    }

    /// True if you don't have a repo with this name yet (GitHub ignores case).
    func isNameAvailable(_ name: String) async throws -> Bool {
        guard let login = profile?.login else { throw Failure(message: "Sign in with GitHub first.") }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let (_, http) = try await api("GET", "/repos/\(login)/\(encoded)")
        switch http.statusCode {
        case 404: return true
        case 200..<400: return false
        default: throw Failure(message: "Couldn't check that name. Try again in a moment.")
        }
    }

    /// Creates a repo under your account with a README, so it has a `main` branch to clone.
    func createRepo(name: String, description: String, isPrivate: Bool) async throws -> Repo {
        var body: [String: Any] = ["name": name, "private": isPrivate, "auto_init": true]
        if !description.isEmpty { body["description"] = description }
        let (data, http) = try await api("POST", "/user/repos", json: body)
        switch http.statusCode {
        case 201:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let repo = try decoder.decode(Repo.self, from: data)
            cachedRepos = [repo] + (cachedRepos ?? [])
            return repo
        case 422: throw Failure(message: "You already have a repo called \(name) on GitHub.")
        case 401, 403, 404: throw Failure(message: "GitHub didn't allow Critique to create repos. Sign in again to give it access.")
        default: throw Failure(message: "GitHub couldn't create the repo. Try again in a moment.")
        }
    }

    /// An Authorization header git can use to clone a private repo you just made.
    /// Passed on the command line only, never written to the repo's config.
    func gitAuthHeader() async -> String? {
        guard let token = await currentToken() else { return nil }
        return "Authorization: Basic " + Data("x-access-token:\(token)".utf8).base64EncodedString()
    }

    private func api(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let token = await currentToken() else { throw Failure(message: "Sign in with GitHub first.") }
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "GitHub didn't answer.") }
        return (data, http)
    }

    // MARK: GitHub device flow

    private struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int?
    }

    private struct TokenReply: Decodable {
        let access_token: String?
        let error: String?
        let error_description: String?
        let interval: Int?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `repo` lets Critique create repos for you (and see your private ones).
    private static let scope = "read:user user:email repo"

    private static func requestDeviceCode(clientID: String) async throws -> DeviceCode {
        try await post("https://github.com/login/device/code",
                       ["client_id": clientID, "scope": Self.scope])
    }

    private static func waitForToken(clientID: String, code: DeviceCode) async throws -> String {
        var interval = max(code.interval ?? 5, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let reply: TokenReply = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.device_code,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = reply.access_token { return token }
            switch reply.error {
            case "authorization_pending": continue
            case "slow_down": interval = reply.interval ?? interval + 5
            case "access_denied": throw Failure(message: "Sign-in was canceled on GitHub.")
            case "expired_token": throw Failure(message: "The code expired. Try signing in again.")
            default: throw Failure(message: reply.error_description ?? "GitHub didn't accept the sign-in.")
            }
        }
        throw Failure(message: "The code expired. Try signing in again.")
    }

    private static func fetchProfile(token: String) async throws -> Profile {
        struct User: Decodable { let login: String; let name: String?; let email: String?; let avatar_url: String? }
        struct Email: Decodable { let email: String; let primary: Bool; let verified: Bool }
        let user: User = try await get("https://api.github.com/user", token: token)
        var email = user.email
        if email == nil, let emails: [Email] = try? await get("https://api.github.com/user/emails", token: token) {
            email = (emails.first { $0.primary && $0.verified } ?? emails.first)?.email
        }
        return Profile(login: user.login, name: user.name, email: email, avatarURL: user.avatar_url.flatMap(URL.init))
    }

    private static func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = parts.percentEncodedQuery?.data(using: .utf8)
        return try await send(request)
    }

    private static func get<T: Decodable>(_ url: String, token: String) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure(message: "GitHub returned an error. Try again in a moment.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Keychain

    nonisolated private static var tokenQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "token"]
    }

    nonisolated private static func saveToken(_ token: String) {
        SecItemDelete(tokenQuery as CFDictionary)
        var item = tokenQuery
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    nonisolated private static func readToken() -> String? {
        var query = tokenQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func deleteToken() {
        SecItemDelete(tokenQuery as CFDictionary)
    }
}
