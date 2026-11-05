import AppKit
import SwiftUI

/// Tells you when a newer Critique is on GitHub.
///
/// Compares this build's version with the latest release tag (v0.2.0 style) a few
/// seconds after launch and then once a day, off the main thread. When there is a
/// newer one, the status menu grows an "Update to 0.x.y…" item and the sidebar shows
/// a small banner; both open the release's DMG so you can drag it over the old app.
///
/// This checks, it doesn't install. The next step is Sparkle, which updates in place
/// but needs an appcast feed and an EdDSA key pair the maintainer generates and keeps
/// (and signed, notarized builds, which the release workflow now makes).
///
/// Opt out of the automatic check with `defaults write dev.critique.app updates.check -bool false`;
/// "Check for Updates…" in the menu always works.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        /// "0.3.0", without the tag's leading "v"
        let version: String
        /// The release notes on GitHub.
        let page: URL
        /// The DMG asset, if the release has one.
        let download: URL?
    }

    /// A release newer than this build, once one is found.
    @Published private(set) var available: Release?
    @Published private(set) var checking = false

    /// "Update to 0.3.0…" in the status menu; hidden until there is something to update to.
    let updateItem = NSMenuItem(title: "Update…", action: #selector(Updater.openDownload), keyEquivalent: "")
    let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(Updater.checkNow), keyEquivalent: "")
    /// Shows a short message the way the rest of Critique does (the pill at the top of the screen).
    var notice: ((String) -> Void)?

    nonisolated static let current: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    nonisolated static let latestURL = URL(string: "https://api.github.com/repos/mmerioles/critique/releases/latest")!
    private static let checkKey = "updates.check"
    private static let skippedKey = "updates.skipped"
    private var daily: Timer?

    private override init() {
        super.init()
        updateItem.target = self
        updateItem.isHidden = true
        checkItem.target = self
    }

    /// Whether Critique looks for updates on its own. Default on.
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Self.checkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.checkKey) }
    }

    /// The version the sidebar banner was closed for; the menu item stays.
    var skipped: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedKey); objectWillChange.send() }
    }

    var bannerVisible: Bool { available != nil && available?.version != skipped }

    /// Checks shortly after launch, then once a day, unless opted out.
    func start() {
        guard automatic else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            Task { await self?.check(manual: false) }
        }
        daily = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automatic else { return }
                await self.check(manual: false)
            }
        }
    }

    /// Asks GitHub for the latest release and remembers it if it's newer than this build.
    /// The network call, JSON parsing and version comparison all run off the main thread.
    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let release = try await Self.fetchLatest()
            if Self.compare(release.version, Self.current) == .orderedDescending {
                available = release
                updateItem.title = "Update to \(release.version)…"
                updateItem.isHidden = false
                if manual { notice?("Critique \(release.version) is out. Update from the menu or the sidebar.") }
            } else if manual {
                notice?("You're up to date (\(Self.current)).")
            }
        } catch {
            log("update check failed: \(error.localizedDescription)")
            if manual { notice?("Couldn't check for updates: \(error.localizedDescription)") }
        }
    }

    @objc func checkNow() {
        Task { await check(manual: true) }
    }

    /// Opens the DMG (the browser downloads it), or the release page if there is no DMG.
    @objc func openDownload() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.download ?? release.page)
    }

    @objc func openReleasePage() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.page)
    }

    // MARK: GitHub

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct LatestRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Critique/\(current)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "GitHub didn't answer.") }
        guard http.statusCode == 200 else { throw Failure(message: "GitHub answered \(http.statusCode).") }
        let latest = try JSONDecoder().decode(LatestRelease.self, from: data)
        let dmg = latest.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
        return Release(version: normalize(latest.tag_name), page: latest.html_url, download: dmg?.browser_download_url)
    }

    // MARK: Versions

    /// "v0.2.0" → "0.2.0"
    nonisolated static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Semantic comparison: numbers by position (missing ones are 0), and a plain
    /// release beats a pre-release of the same number (0.3.0 > 0.3.0-beta.1).
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (aCore, aPre) = split(normalize(a))
        let (bCore, bPre) = split(normalize(b))
        for i in 0..<max(aCore.count, bCore.count) {
            let x = i < aCore.count ? aCore[i] : 0
            let y = i < bCore.count ? bCore[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (aPre, bPre) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (p?, q?): return comparePrerelease(p, q)
        }
    }

    /// "1.2.3-beta.1+build" → ([1, 2, 3], "beta.1")
    nonisolated private static func split(_ version: String) -> ([Int], String?) {
        let noBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
        let parts = noBuild.split(separator: "-", maxSplits: 1)
        let core = (parts.first.map(String.init) ?? "").split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let pre = parts.count > 1 ? String(parts[1]) : nil
        return (core, pre)
    }

    /// Dot-separated identifiers: numbers compare as numbers, words alphabetically, numbers before words.
    nonisolated private static func comparePrerelease(_ a: String, _ b: String) -> ComparisonResult {
        let xs = a.split(separator: "."), ys = b.split(separator: ".")
        for (x, y) in zip(xs, ys) {
            switch (Int(x), Int(y)) {
            case let (m?, n?): if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (nil, nil): if x != y { return x < y ? .orderedAscending : .orderedDescending }
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            }
        }
        if xs.count == ys.count { return .orderedSame }
        return xs.count < ys.count ? .orderedAscending : .orderedDescending
    }
}

/// The sidebar's "a newer Critique is out" card: download, release notes, or close it for this version.
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let release = updater.available, updater.bannerVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.red)
                    Text("Critique \(release.version) is out").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Button { updater.skipped = release.version } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Hide this for \(release.version)")
                }
                Text("You have \(Updater.current). Download the new one and drag it over the old app.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Download") { updater.openDownload() }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.banner))
                        .foregroundStyle(.white)
                    Button("What's new") { updater.openReleasePage() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .padding(.bottom, 10)
        }
    }
}
