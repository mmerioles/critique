import Foundation

/// The git projects on this Mac, and which one your critiques are for.
///
/// Picking a project tags every critique with its folder, so the agent working
/// there picks it up (and later, so Critique can start the agent there itself).
@MainActor
final class Projects: ObservableObject {
    static let shared = Projects()

    struct Local: Identifiable, Equatable {
        let path: URL
        /// owner/name when it comes from GitHub, otherwise the folder name
        let name: String
        let branch: String?
        /// Local branches, then origin's branches you don't have locally yet.
        let branches: [String]
        let remoteBranches: [String]
        let remote: String?
        let lastActive: Date
        var id: String { path.path }
        /// owner/name, lowercased, for matching against GitHub repos
        var slug: String? { remote.flatMap(Projects.slug(fromRemote:))?.lowercased() }
    }

    @Published private(set) var local: [Local] = []
    @Published private(set) var active: FeedbackRecord.ProjectRecord?
    @Published private(set) var scanning = false

    nonisolated private static let activeKey = "project.active"
    private static let foldersKey = "project.folders"

    /// Where people usually keep their code. Folders you add are searched too.
    nonisolated static let usualFolders = ["repos", "Developer", "Projects", "projects", "code", "Code", "src", "dev",
                               "GitHub", "Documents/GitHub", "workspace"]

    private init() {
        active = Self.activeRecord()
    }

    // MARK: Upstream changes

    /// How a repo compares to its upstream branch, after a fetch.
    enum Sync: Equatable {
        case checking
        case pulling
        case upToDate
        case behind(Int)
        case ahead(Int)
        case diverged(behind: Int, ahead: Int)
        case noUpstream
        case failed(String)
    }

    @Published private(set) var sync: [String: Sync] = [:]

    var checkingAny: Bool { sync.values.contains(.checking) }
    var pullingAny: Bool { sync.values.contains(.pulling) }

    /// Repos a fast-forward pull would bring up to date.
    var behind: [Local] {
        local.filter { if case .behind = sync[$0.id] { true } else { false } }
    }

    /// Pulls every repo that's behind (four at a time).
    func updateAll() {
        let repos = behind
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (index, repo) in repos.enumerated() {
                    if index >= 4 { await group.next() }
                    group.addTask { await self.pull(repo) }
                }
            }
        }
    }

    /// Fast-forwards the current branch to upstream. Never merges or rebases, so it
    /// either updates cleanly or leaves the repo as it was.
    func pull(_ repo: Local) async {
        sync[repo.id] = .pulling
        let dir = repo.path
        sync[repo.id] = await Task.detached(priority: .utility) { () -> Sync in
            let pull = Self.git(["pull", "--ff-only", "--quiet", "--no-tags"], in: dir, timeout: 60)
            guard pull.status == 0 else {
                let reason = pull.error.lowercased()
                if reason.contains("not possible to fast-forward") || reason.contains("diverg") { return .failed("Can't fast-forward") }
                if reason.contains("would be overwritten") { return .failed("Local changes") }
                if reason.contains("timed out") { return .failed("Timed out") }
                return .failed("Couldn't pull")
            }
            return Self.compare(dir)
        }.value
        reload(repo)
    }

    struct GitFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Checks out another branch. A remote-only branch gets a local branch tracking it.
    func switchBranch(_ repo: Local, to branch: String) async throws {
        let dir = repo.path
        let result = await Task.detached(priority: .userInitiated) {
            Self.git(["switch", "--quiet", branch], in: dir, timeout: 30)
        }.value
        if result.status != 0 {
            let first = result.error.split(separator: "\n").first.map(String.init) ?? "Couldn't switch branches."
            throw GitFailure(message: "\(repo.name): " + first.replacingOccurrences(of: "error: ", with: ""))
        }
        sync[repo.id] = nil
        reload(repo)
    }

    /// Re-reads one repo (its branch may have changed) and keeps the picked project in step.
    private func reload(_ repo: Local) {
        guard let fresh = Self.repo(at: repo.path), let index = local.firstIndex(where: { $0.id == repo.id }) else { return }
        local[index] = fresh
        if active?.path == fresh.path.path { select(fresh) }
    }

    /// Fetches every repo (four at a time) and counts commits to pull.
    func checkAll() {
        let repos = local
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (index, repo) in repos.enumerated() {
                    if index >= 4 { await group.next() }
                    group.addTask { await self.check(repo) }
                }
            }
        }
    }

    /// Fetches from the remote and compares. Only updates remote-tracking refs;
    /// your branch and files stay as they are.
    func check(_ repo: Local) async {
        sync[repo.id] = .checking
        let dir = repo.path
        sync[repo.id] = await Task.detached(priority: .utility) { Self.compare(dir) }.value
    }

    nonisolated private static func compare(_ dir: URL) -> Sync {
        guard git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: dir).status == 0 else { return .noUpstream }
        let fetch = git(["fetch", "--quiet", "--no-tags"], in: dir, timeout: 30)
        guard fetch.status == 0 else {
            let reason = fetch.error.lowercased()
            if reason.contains("timed out") { return .failed("Timed out") }
            if reason.contains("auth") || reason.contains("permission") || reason.contains("could not read") { return .failed("Can't sign in") }
            return .failed("Couldn't fetch")
        }
        let counts = git(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: dir)
        let parts = counts.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.status == 0, parts.count == 2 else { return .failed("Couldn't compare") }
        switch (parts[0], parts[1]) {
        case (0, 0): return .upToDate
        case (let behind, 0): return .behind(behind)
        case (0, let ahead): return .ahead(ahead)
        case (let behind, let ahead): return .diverged(behind: behind, ahead: ahead)
        }
    }

    /// Runs git without ever stopping to ask for a password.
    nonisolated static func git(_ args: [String], in dir: URL, timeout: TimeInterval = 10,
                                extraEnv: [String: String] = [:]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
        env.merge(extraEnv) { $1 }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Read both pipes while git runs. Waiting first would stall git as soon as
        // it printed more than a pipe holds (64 KB), until the timeout.
        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = data } else { errData = data }
                group.leave()
            }
        }
        do { try process.run() } catch {
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            return (-1, "", error.localizedDescription)
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            group.wait()
            return (-1, "", "timed out")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    // MARK: Picking

    func select(_ project: Local?) {
        guard let project else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
            active = nil
            return
        }
        let record = FeedbackRecord.ProjectRecord(name: project.name, path: project.path.path,
                                                  branch: project.branch, remote: project.remote)
        UserDefaults.standard.set(try? JSONEncoder().encode(record), forKey: Self.activeKey)
        active = record
    }

    /// The picked project, with its current branch. Safe to call from any thread.
    nonisolated static func activeRecord() -> FeedbackRecord.ProjectRecord? {
        guard let data = UserDefaults.standard.data(forKey: activeKey),
              var record = try? JSONDecoder().decode(FeedbackRecord.ProjectRecord.self, from: data),
              FileManager.default.fileExists(atPath: record.path) else { return nil }
        record.branch = branch(at: URL(fileURLWithPath: record.path)) ?? record.branch
        return record
    }

    // MARK: Finding repos

    var addedFolders: [String] { UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? [] }

    func add(folder: URL) {
        var folders = addedFolders
        if !folders.contains(folder.path) { folders.append(folder.path) }
        UserDefaults.standard.set(folders, forKey: Self.foldersKey)
        Task { await refresh() }
    }

    func refresh() async {
        scanning = true
        let added = addedFolders + [Agents.shared.root.path] // always include the agent's folder
        local = await Task.detached(priority: .utility) { Self.scan(added: added) }.value
        scanning = false
    }

    /// Where a clone goes: ~/repos, or the first of the usual folders you already have.
    nonisolated static var cloneFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let existing = usualFolders.map { home.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return existing ?? home.appendingPathComponent("repos")
    }

    /// Clones a GitHub repo into the clone folder and picks it.
    /// `authHeader` lets git clone a private repo without asking for a password.
    func clone(_ repo: GitHubAccount.Repo, authHeader: String? = nil) async throws {
        let folder = Self.cloneFolder
        let dest = folder.appendingPathComponent(repo.name)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw GitHubAccount.Failure(message: "\(dest.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) already exists.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let status: Int32 = try await Task.detached {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            let auth = authHeader.map { ["-c", "http.https://github.com/.extraheader=\($0)"] } ?? []
            git.arguments = auth + ["clone", "--quiet", repo.clone_url, dest.path]
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            git.environment = env
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try git.run()
            git.waitUntilExit()
            return git.terminationStatus
        }.value
        guard status == 0 else { throw GitHubAccount.Failure(message: "Couldn't clone \(repo.full_name).") }
        await refresh()
        if let cloned = local.first(where: { $0.path.standardizedFileURL == dest.standardizedFileURL }) { select(cloned) }
    }

    /// Moves a repo's folder to the Trash, so it can still be put back from Finder.
    func trash(_ repo: Local) throws {
        try FileManager.default.trashItem(at: repo.path, resultingItemURL: nil)
        local.removeAll { $0.id == repo.id }
        sync[repo.id] = nil
        if active?.path == repo.path.path { select(nil) }
    }

    /// Uncommitted changes and commits not on any remote: what deleting would lose
    /// if the Trash were emptied.
    nonisolated static func unsaved(_ repo: Local) -> (changes: Bool, unpushed: Int) {
        let status = git(["status", "--porcelain"], in: repo.path)
        let unpushed = git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: repo.path)
        return (!status.output.isEmpty, Int(unpushed.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    nonisolated private static func scan(added: [String]) -> [Local] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = usualFolders.map { home.appendingPathComponent($0) } + added.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        var found: [Local] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for dir in [root] + children {
                let path = dir.resolvingSymlinksInPath().path
                guard !seen.contains(path), let repo = repo(at: dir) else { continue }
                seen.insert(path)
                found.append(repo)
            }
        }
        return found.sorted { $0.lastActive > $1.lastActive }
    }

    nonisolated private static func repo(at dir: URL) -> Local? {
        let git = dir.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: git.path) else { return nil }
        let remote = originURL(at: git)
        let name = remote.flatMap(slug(fromRemote:)) ?? dir.lastPathComponent
        let dates = ["index", "HEAD"].compactMap {
            try? git.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let refs = Self.git(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin"], in: dir)
            .output.split(separator: "\n").map(String.init)
        let branches = refs.filter { $0.hasPrefix("refs/heads/") }.map { String($0.dropFirst("refs/heads/".count)) }
        let remoteBranches = refs.filter { $0.hasPrefix("refs/remotes/origin/") }
            .map { String($0.dropFirst("refs/remotes/origin/".count)) }
            .filter { $0 != "HEAD" && !branches.contains($0) }
        return Local(path: dir, name: name, branch: branch(at: dir), branches: branches, remoteBranches: remoteBranches,
                     remote: remote, lastActive: dates.max() ?? .distantPast)
    }

    nonisolated static func branch(at dir: URL) -> String? {
        guard let head = try? String(contentsOf: dir.appendingPathComponent(".git/HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("ref: refs/heads/") ? String(line.dropFirst("ref: refs/heads/".count)) : nil
    }

    nonisolated private static func originURL(at git: URL) -> String? {
        guard let config = try? String(contentsOf: git.appendingPathComponent("config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            if inOrigin, line.hasPrefix("url") , let eq = line.firstIndex(of: "=") {
                return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// "owner/name" from git@github.com:owner/name.git or https://github.com/owner/name
    nonisolated static func slug(fromRemote remote: String) -> String? {
        guard let range = remote.range(of: "github.com") else { return nil }
        var rest = remote[range.upperBound...].drop { $0 == ":" || $0 == "/" }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/")
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }
}
