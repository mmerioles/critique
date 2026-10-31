import AppKit
import SwiftUI

/// Keep the repos on this Mac up to date, clone ones from GitHub, and clean up old ones.
/// Which repo critiques go to is picked on the Agent page.
struct ReposPage: View {
    @ObservedObject private var projects = Projects.shared
    @ObservedObject private var github = GitHubAccount.shared
    @State private var remote: [GitHubAccount.Repo] = []
    @State private var loadingRemote = false
    @State private var cloning: String?
    @State private var switching: String?
    @State private var error: String?
    @State private var deleting: Projects.Local?
    @State private var deletingUnsaved: (changes: Bool, unpushed: Int) = (false, 0)
    @State private var creatingProject = false

    var body: some View {
        PageScaffold(title: "Repos", subtitle: "Keep your projects up to date.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    section("On this Mac")
                    Spacer()
                    Button {
                        creatingProject = true
                    } label: {
                        Label("New Project…", systemImage: "plus")
                    }
                    .help("Create an empty repo on GitHub and clone it here")
                    Button {
                        guard !projects.checkingAny else { return }
                        projects.checkAll()
                    } label: {
                        HStack(spacing: 6) {
                            // While checking, show the same dial spinner the repo rows use, in the icon's slot.
                            ZStack {
                                Image(systemName: "arrow.clockwise").opacity(projects.checkingAny ? 0 : 1)
                                if projects.checkingAny {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            // Both titles share one slot sized to the wider one, so the button keeps its width while checking.
                            ZStack(alignment: .leading) {
                                Text("Check for Updates").opacity(projects.checkingAny ? 0 : 1)
                                Text("Checking…").opacity(projects.checkingAny ? 1 : 0)
                            }
                        }
                    }
                    // Stays enabled (not dimmed) while checking so the spinner reads clearly; the guard ignores extra clicks.
                    .disabled(projects.local.isEmpty)
                    .help("Fetch every repo and see what's new upstream. Nothing is pulled.")
                    if !projects.behind.isEmpty || projects.pullingAny {
                        Button {
                            projects.updateAll()
                        } label: {
                            Label(projects.pullingAny ? "Updating…" : "Update All (\(projects.behind.count))", systemImage: "arrow.down")
                        }
                        .disabled(projects.pullingAny || projects.behind.isEmpty)
                        .help("Fast-forward every repo that's behind. Repos with local commits or conflicting changes are left alone.")
                    }
                    Button("Add Folder…", action: addFolder)
                }
                // Drawn by SwiftUI instead of AppKit: a native macOS button flattens its label,
                // which freezes the spinner and lets the button shrink while checking.
                .buttonStyle(HeaderButtonStyle())
                if !projects.local.isEmpty {
                    RowList {
                        ForEach(Array(projects.local.enumerated()), id: \.element.id) { index, repo in
                            if index > 0 { Divider().overlay(Theme.border) }
                            localRow(repo)
                        }
                    }
                }
                if projects.local.isEmpty && !projects.scanning {
                    Text("No git projects found in ~/repos, ~/Developer or ~/Projects. Add the folder where you keep your code.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                section("On GitHub")
                if github.profile == nil {
                    signInRow
                } else if notCloned.isEmpty {
                    Text(loadingRemote ? "Loading your repos…" : "Every repo you've pushed to lately is already on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    RowList {
                        ForEach(Array(notCloned.enumerated()), id: \.element.id) { index, repo in
                            if index > 0 { Divider().overlay(Theme.border) }
                            remoteRow(repo)
                        }
                    }
                }
            }

        }
        .task { await projects.refresh() }
        .confirmationDialog("Move \(deleting?.name ?? "") to the Trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let repo = deleting { delete(repo) }
                deleting = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .task(id: github.profile?.login) { await loadRemote() }
        // The New Project sheet shows its own sign-in code while it's open.
        .sheet(item: Binding(get: { creatingProject ? nil : github.pending.map(PendingBox.init) },
                             set: { if $0 == nil { github.cancelSignIn() } })) { box in
            DeviceCodeSheet(pending: box.pending) { github.cancelSignIn() }
        }
        .sheet(isPresented: $creatingProject, onDismiss: { Task { await loadRemote() } }) {
            NewProjectSheet { creatingProject = false }
        }
    }

    /// GitHub repos you don't have a copy of yet.
    private var notCloned: [GitHubAccount.Repo] {
        let here = Set(projects.local.compactMap(\.slug))
        return remote.filter { !here.contains($0.full_name.lowercased()) }.prefix(12).map { $0 }
    }

    // MARK: Rows

    private func localRow(_ repo: Projects.Local) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.system(size: 14))
                Text(repo.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            branchMenu(repo)
            syncLabel(repo, fallback: relative(repo.lastActive))
                .frame(width: 96, alignment: .trailing)
            Button {
                Task { await projects.check(repo) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(projects.sync[repo.id] == .checking || projects.sync[repo.id] == .pulling)
            .help("Check for upstream changes")
            DeleteButton { confirmDelete(repo) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .contextMenu {
            if case .behind = projects.sync[repo.id] {
                Button("Pull") { Task { await projects.pull(repo) } }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repo.path]) }
            if let slug = repo.remote.flatMap(Projects.slug(fromRemote:)), let url = URL(string: "https://github.com/\(slug)") {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { confirmDelete(repo) }
        }
    }

    private func remoteRow(_ repo: GitHubAccount.Repo) -> some View {
        HStack(spacing: 14) {
            GitHubMark().frame(width: 16, height: 16).foregroundStyle(Theme.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.full_name).font(.system(size: 14))
                    if repo.private { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                }
                if let description = repo.description, !description.isEmpty {
                    Text(description).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let pushed = repo.pushed_at {
                Text(relative(pushed)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            if cloning == repo.id {
                ProgressView().controlSize(.small).frame(width: 60)
            } else {
                Button("Clone") { clone(repo) }
                    .disabled(cloning != nil)
                    .help("Clone into \(Projects.cloneFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .contextMenu {
            if let url = URL(string: repo.html_url) { Button("Open on GitHub") { NSWorkspace.shared.open(url) } }
        }
    }

    private var signInRow: some View {
        RowList {
            HStack(spacing: 14) {
                GitHubMark().frame(width: 16, height: 16).frame(width: 20)
                Text("Sign in to see your GitHub repos").font(.system(size: 14))
                Spacer()
                Button("Sign in with GitHub") { github.startSignIn() }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
    }

    // MARK: Actions

    private func loadRemote() async {
        guard github.profile != nil else { remote = []; return }
        loadingRemote = true
        do { remote = try await github.repos() } catch { self.error = error.localizedDescription }
        loadingRemote = false
    }

    private func clone(_ repo: GitHubAccount.Repo) {
        cloning = repo.id
        error = nil
        Task {
            do { try await projects.clone(repo) } catch { self.error = error.localizedDescription }
            cloning = nil
        }
    }

    private func switchBranch(_ repo: Projects.Local, to branch: String) {
        switching = repo.id
        error = nil
        Task {
            do { try await projects.switchBranch(repo, to: branch) } catch { self.error = error.localizedDescription }
            switching = nil
        }
    }

    private func confirmDelete(_ repo: Projects.Local) {
        deletingUnsaved = Projects.unsaved(repo)
        deleting = repo
    }

    private var deleteMessage: String {
        guard let repo = deleting else { return "" }
        let path = repo.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        var lines = ["Deletes \(path) from this Mac. Nothing on GitHub changes, and you can put it back from the Trash."]
        let n = deletingUnsaved.unpushed
        if n > 0 { lines.append("It has \(n) commit\(n == 1 ? "" : "s") that aren't pushed anywhere.") }
        if deletingUnsaved.changes { lines.append("It has uncommitted changes.") }
        return lines.joined(separator: "\n\n")
    }

    private func delete(_ repo: Projects.Local) {
        error = nil
        do { try projects.trash(repo) } catch { self.error = "Couldn't delete \(repo.name): \(error.localizedDescription)" }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Pick a project, or the folder where you keep your projects."
        if panel.runModal() == .OK, let url = panel.url { projects.add(folder: url) }
    }

    // MARK: Helpers

    /// The current branch. Click it to switch to another one.
    private func branchMenu(_ repo: Projects.Local) -> some View {
        Menu {
            Section("Branches") {
                ForEach(repo.branches, id: \.self) { branch in
                    Button {
                        switchBranch(repo, to: branch)
                    } label: {
                        if branch == repo.branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                    }
                    .disabled(branch == repo.branch)
                }
            }
            if !repo.remoteBranches.isEmpty {
                Section("On origin") {
                    ForEach(repo.remoteBranches, id: \.self) { branch in
                        Button(branch) { switchBranch(repo, to: branch) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(repo.branch ?? "detached")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(repo.branches.isEmpty || switching == repo.id)
        .help("Switch branches")
    }

    @ViewBuilder private func syncLabel(_ repo: Projects.Local, fallback: String) -> some View {
        switch projects.sync[repo.id] {
        case nil:
            Text(fallback).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        case .checking, .pulling:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        case .behind(let n):
            Button {
                Task { await projects.pull(repo) }
            } label: {
                Label("Pull \(n)", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
            }
            .controlSize(.small)
            .help("Fast-forward to the \(n) new commit\(n == 1 ? "" : "s") upstream")
        case .ahead(let n):
            Label("\(n) to push", systemImage: "arrow.up").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        case .diverged(let behind, let ahead):
            Text("↓\(behind) ↑\(ahead)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.red)
                .help("\(behind) to pull, \(ahead) to push")
        case .noUpstream:
            Text("No upstream").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        case .failed(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(Color.orange)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 12, weight: .medium)).kerning(1.2).foregroundStyle(Theme.secondary)
    }

    private func relative(_ date: Date) -> String {
        guard date > .distantPast else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// A small X that turns red when you point at it.
    private struct DeleteButton: View {
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? Theme.red : Theme.tertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(hovering ? Theme.red.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Delete from this Mac")
        }
    }

    private struct PendingBox: Identifiable {
        let pending: GitHubAccount.Pending
        var id: String { pending.userCode }
    }
}

/// A push button drawn in SwiftUI that looks like the standard macOS one,
/// so animated labels (like a spinning symbol) keep working.
private struct HeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Color.black.opacity(configuration.isPressed ? 0.16 : 0.09),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}
