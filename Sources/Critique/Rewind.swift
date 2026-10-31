import Foundation

/// Undo for critiques: puts a project back the way it was before a critique.
///
/// When a critique is saved, Critique takes a snapshot of the project: the commit
/// it was on plus every uncommitted and untracked file (ignored files aren't
/// touched). The snapshot is a commit kept under refs/critique/, built with a
/// separate index, so taking it never changes your branch, staging, or files.
///
/// Undo first snapshots how things are now (so you can redo), then moves the
/// branch back to the old commit and restores the old files.
enum Rewind {
    struct Point: Codable, Equatable {
        /// The commit HEAD was on
        var head: String
        /// The branch it was on; nil when HEAD was detached
        var branch: String?
        /// Commit holding the full working tree, kept at refs/critique/<name>
        var snapshot: String
    }

    enum Failure: LocalizedError {
        case notARepo
        case otherBranch(String)
        case nothingChanged
        case git(String)

        var errorDescription: String? {
            switch self {
            case .notARepo: "Not a git repo"
            case .otherBranch(let branch): "Switch back to \(branch) first"
            case .nothingChanged: "Nothing to undo"
            case .git(let message): message
            }
        }
    }

    /// Records how `repo` looks right now. Nil if it isn't a git repo with a commit.
    static func snapshot(_ repo: URL, name: String) -> Point? {
        guard let head = git(["rev-parse", "--verify", "-q", "HEAD"], repo) else { return nil }
        let branch = git(["symbolic-ref", "--short", "-q", "HEAD"], repo)

        // A throwaway index, so your real staging area is never touched.
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("critique-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        guard git(["read-tree", head], repo, env: env) != nil,
              git(["add", "-A", "--", ":/"], repo, env: env, timeout: 60) != nil,
              let tree = git(["write-tree"], repo, env: env) else { return nil }

        let who = ["GIT_AUTHOR_NAME": "Critique", "GIT_AUTHOR_EMAIL": "critique@localhost",
                   "GIT_COMMITTER_NAME": "Critique", "GIT_COMMITTER_EMAIL": "critique@localhost"]
        guard let commit = git(["commit-tree", tree, "-p", head, "-m", "Critique snapshot \(name)"], repo, env: who),
              git(["update-ref", "refs/critique/\(name)", commit], repo) != nil else { return nil }
        return Point(head: head, branch: branch, snapshot: commit)
    }

    /// Puts `repo` back to `point`. Returns a snapshot of how it was just before,
    /// which restores it again (redo).
    static func restore(_ repo: URL, to point: Point, name: String) throws -> Point {
        guard git(["rev-parse", "--git-dir"], repo) != nil else { throw Failure.notARepo }
        let branch = git(["symbolic-ref", "--short", "-q", "HEAD"], repo)
        if branch != point.branch { throw Failure.otherBranch(point.branch ?? "the commit it was on") }

        guard let now = snapshot(repo, name: name) else { throw Failure.git("Couldn't save the current state") }
        if now.head == point.head, tree(now.snapshot, repo) == tree(point.snapshot, repo) {
            throw Failure.nothingChanged
        }

        // 1. Move the branch back. Newer commits stay reachable from the redo snapshot.
        try run(["reset", "-q", "--hard", point.head], repo)

        // 2. Remove files that didn't exist back then (ignored files are left alone).
        let then = Set(list(["ls-tree", "-r", "-z", "--name-only", point.snapshot], repo))
        let root = URL(fileURLWithPath: git(["rev-parse", "--show-toplevel"], repo) ?? repo.path)
        for file in list(["ls-files", "-z", "-co", "--exclude-standard"], repo) where !then.contains(file) {
            let url = root.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: url)
            removeEmptyParents(of: url, below: root)
        }

        // 3. Bring back the uncommitted and untracked files, then unstage them,
        //    so they're plain local changes again like before.
        if !then.isEmpty { try run(["checkout", point.snapshot, "--", ":/"], repo) }
        try run(["reset", "-q"], repo)
        return now
    }

    /// Drops the snapshots kept for a critique.
    static func forget(_ repo: URL, name: String) {
        for ref in ["refs/critique/\(name)", "refs/critique/\(name)-redo"] {
            _ = git(["update-ref", "-d", ref], repo)
        }
    }

    // MARK: git

    private static func tree(_ commit: String, _ repo: URL) -> String? {
        git(["rev-parse", "\(commit)^{tree}"], repo)
    }

    private static func list(_ args: [String], _ repo: URL) -> [String] {
        let result = Projects.git(["-c", "core.quotepath=off"] + args, in: repo, timeout: 30)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\0").map(String.init)
    }

    private static func run(_ args: [String], _ repo: URL) throws {
        let result = Projects.git(args, in: repo, timeout: 60)
        guard result.status == 0 else {
            throw Failure.git(result.error.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "git failed")
        }
    }

    /// Trimmed output, or nil if git failed.
    private static func git(_ args: [String], _ repo: URL, env: [String: String] = [:], timeout: TimeInterval = 10) -> String? {
        let result = Projects.git(args, in: repo, timeout: timeout, extraEnv: env)
        guard result.status == 0 else { return nil }
        let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty && !["add", "read-tree", "update-ref"].contains(args.first ?? "") ? nil : out
    }

    private static func removeEmptyParents(of url: URL, below root: URL) {
        var dir = url.deletingLastPathComponent()
        while dir.path.count > root.path.count,
              (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }
}
