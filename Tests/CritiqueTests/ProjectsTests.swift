import Foundation
import Testing
@testable import Critique

struct ProjectsTests {
    @Test func slugFromGitHubRemotes() {
        #expect(Projects.slug(fromRemote: "git@github.com:owner/name.git") == "owner/name")
        #expect(Projects.slug(fromRemote: "git@github.com:owner/name") == "owner/name")
        #expect(Projects.slug(fromRemote: "https://github.com/owner/name") == "owner/name")
        #expect(Projects.slug(fromRemote: "https://github.com/owner/name.git") == "owner/name")
        #expect(Projects.slug(fromRemote: "ssh://git@github.com/owner/name.git") == "owner/name")
        #expect(Projects.slug(fromRemote: "https://github.com/Owner/My-Repo.git") == "Owner/My-Repo")
    }

    @Test func slugRejectsOtherRemotes() {
        #expect(Projects.slug(fromRemote: "https://gitlab.com/owner/name.git") == nil)
        #expect(Projects.slug(fromRemote: "https://github.com/owner") == nil)
        #expect(Projects.slug(fromRemote: "https://github.com/a/b/c") == nil)
        #expect(Projects.slug(fromRemote: "") == nil)
        #expect(Projects.slug(fromRemote: "/Users/me/repos/name") == nil)
    }

    @Test func branchOfARealRepo() throws {
        try withTemporaryDirectory { dir in
            let result = Projects.git(["init", "--quiet", "--initial-branch=main", dir.path], in: dir)
            try #require(result.status == 0, "git init failed: \(result.error)")
            #expect(Projects.branch(at: dir) == "main")

            let switched = Projects.git(["symbolic-ref", "HEAD", "refs/heads/feature/pointer-ring"], in: dir)
            try #require(switched.status == 0, "symbolic-ref failed: \(switched.error)")
            #expect(Projects.branch(at: dir) == "feature/pointer-ring")
        }
    }

    @Test func branchIsNilWhenDetachedOrNotARepo() throws {
        try withTemporaryDirectory { dir in
            #expect(Projects.branch(at: dir) == nil)
            let git = dir.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try "3dcf6c43a6a0e0d8e1b2c9b61a0f1b9b7e0c8f21\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
            #expect(Projects.branch(at: dir) == nil)
            try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
            #expect(Projects.branch(at: dir) == "main")
        }
    }

    @Test func gitReportsFailures() {
        withTemporaryDirectory { dir in
            let result = Projects.git(["rev-parse", "HEAD"], in: dir)
            #expect(result.status != 0)
            #expect(!result.error.isEmpty)
        }
    }
}
