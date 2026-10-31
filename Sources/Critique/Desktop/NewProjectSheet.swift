import AppKit
import SwiftUI

/// Makes an empty repo on your GitHub account and clones it onto this Mac.
/// Checks the name as you type and shows a green check when it's free.
struct NewProjectSheet: View {
    let close: () -> Void

    @ObservedObject private var github = GitHubAccount.shared
    @ObservedObject private var projects = Projects.shared
    @State private var name = ""
    @State private var summary = ""
    @State private var isPrivate = true
    @State private var status: NameStatus = .empty
    @State private var canCreate: Bool?
    @State private var creating = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    enum NameStatus: Equatable {
        case empty
        case checking
        case available
        case invalid(String)
        case taken(String)
        case failed(String)
    }

    var body: some View {
        Group {
            if let pending = github.pending {
                DeviceCodeSheet(pending: pending) { github.cancelSignIn() }
            } else {
                form
            }
        }
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
        .presentationBackground(Theme.panel)
        .preferredColorScheme(.light)
        // Check access again after a fresh sign-in.
        .task(id: github.pending == nil) {
            guard github.pending == nil, github.profile != nil else { return }
            canCreate = await github.canCreateRepos()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Project").font(.system(size: 18, weight: .semibold))
                Text("Creates an empty repo on GitHub and clones it to \(folder).")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }

            if github.profile == nil {
                accessRow(text: "Sign in with GitHub to create projects.", button: "Sign in with GitHub")
            } else if canCreate == false {
                accessRow(text: "Critique needs permission to create repos on your GitHub account.",
                          button: "Give Access on GitHub")
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Name")
                HStack(spacing: 8) {
                    Text("\(github.profile?.login ?? "you") /")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    TextField("my-project", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(create)
                    statusIcon.frame(width: 18)
                }
                statusText.frame(height: 16, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Description (optional)")
                TextField("", text: $summary).textFieldStyle(.roundedBorder)
            }

            Picker("", selection: $isPrivate) {
                Text("Private").tag(true)
                Text("Public").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(action: create) {
                    if creating {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Creating…") }
                    } else {
                        Text("Create Project")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
        }
        .padding(28)
        .frame(width: 440)
        .onAppear { nameFocused = true }
        .task(id: name) { await check() }
        .disabled(creating)
    }

    // MARK: Pieces

    private func accessRow(text: String, button: String) -> some View {
        HStack(spacing: 12) {
            GitHubMark().frame(width: 16, height: 16)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Button(button) { github.startSignIn() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .empty: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale)
        case .invalid, .taken:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case .empty: Text(" ").font(.system(size: 12))
        case .checking: Text("Checking GitHub…").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        case .available:
            Text("\(name) is available").font(.system(size: 12)).foregroundStyle(.green)
        case .invalid(let why), .taken(let why), .failed(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(status == .failed(why) ? .orange : Theme.red)
        }
    }

    private var folder: String {
        Projects.cloneFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var ready: Bool {
        status == .available && canCreate == true && !creating
    }

    // MARK: Actions

    /// Waits for typing to pause, then asks GitHub whether the name is free.
    private func check() async {
        error = nil
        let candidate = name
        if let problem = GitHubAccount.nameProblem(candidate) {
            status = problem.isEmpty ? .empty : .invalid(problem)
            return
        }
        if FileManager.default.fileExists(atPath: Projects.cloneFolder.appendingPathComponent(candidate).path) {
            status = .taken("\(folder)/\(candidate) already exists on this Mac.")
            return
        }
        guard github.profile != nil else { status = .empty; return }
        status = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let free = try await github.isNameAvailable(candidate)
            guard !Task.isCancelled, candidate == name else { return }
            withAnimation(.spring(duration: 0.25)) {
                status = free ? .available : .taken("You already have a repo called \(candidate).")
            }
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }

    private func create() {
        guard ready else { return }
        creating = true
        error = nil
        let repoName = name
        Task {
            defer { creating = false }
            do {
                let repo = try await github.createRepo(name: repoName, description: summary, isPrivate: isPrivate)
                let auth = await github.gitAuthHeader()
                // GitHub can take a moment before a brand-new repo is ready to clone.
                var attempt = 0
                while true {
                    do {
                        try await projects.clone(repo, authHeader: auth)
                        break
                    } catch where attempt < 3 {
                        attempt += 1
                        try? await Task.sleep(for: .seconds(1.5))
                    } catch {
                        throw GitHubAccount.Failure(message: "Created \(repo.full_name) on GitHub, but couldn't clone it. Clone it from the list below.")
                    }
                }
                close()
            } catch {
                self.error = error.localizedDescription
                status = .empty
                await check()
            }
        }
    }
}
