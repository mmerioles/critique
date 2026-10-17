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
    private static let keychainService = "dev.critique.github"

    static var clientID: String? {
        let id = (Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String)?
            .trimmingCharacters(in: .whitespaces)
        return id?.isEmpty == false ? id : nil
    }

    var isConfigured: Bool { Self.clientID != nil }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.profileKey), Self.readToken() != nil {
            profile = try? JSONDecoder().decode(Profile.self, from: data)
        }
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
                Self.saveToken(token)
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
        Self.deleteToken()
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        profile = nil
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

    private static func requestDeviceCode(clientID: String) async throws -> DeviceCode {
        try await post("https://github.com/login/device/code",
                       ["client_id": clientID, "scope": "read:user user:email"])
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

    private static var tokenQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "token"]
    }

    private static func saveToken(_ token: String) {
        SecItemDelete(tokenQuery as CFDictionary)
        var item = tokenQuery
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func readToken() -> String? {
        var query = tokenQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteToken() {
        SecItemDelete(tokenQuery as CFDictionary)
    }
}
