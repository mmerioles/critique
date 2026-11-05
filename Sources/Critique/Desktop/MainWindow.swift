import AppKit
import SwiftUI

/// Critique's desktop window: your critiques over time, plus how to connect an agent.
@MainActor
final class MainWindow: NSWindowController, NSWindowDelegate {
    init(store: CritiqueStore, handoff: AgentHandoff) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Critique"
        window.minSize = NSSize(width: 860, height: 560)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.sidebar)
        // Critique's window is always light. Pinning the appearance here (not
        // just SwiftUI's colorScheme) carries it into every sheet and AppKit
        // control, so a Mac in dark mode can't put light-theme text on a dark sheet.
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = NSHostingController(rootView: RootView(store: store, handoff: handoff))
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()
        window.setFrameAutosaveName("CritiqueMainWindow")
        super.init(window: window)
        window.delegate = self
        ScreenCapture.keepWindows.insert(CGWindowID(window.windowNumber))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Light-only palette (see MainWindow). Text greys meet WCAG AA on white, and
/// go darker still when the Mac has Accessibility → Display → Increase contrast on.
enum Theme {
    static let sidebar = Color(red: 0.965, green: 0.957, blue: 0.945)   // warm off-white
    static let panel = Color.white
    static let border = adaptive(0.91, 0.9, 0.88, contrast: (0.62, 0.61, 0.59))
    static let selected = Color(red: 0.925, green: 0.914, blue: 0.894)
    static let hover = Color(red: 0.98, green: 0.976, blue: 0.968)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// Body help text: 5.4:1 on white.
    static let secondary = adaptive(0.43, 0.42, 0.40, contrast: (0.28, 0.27, 0.26))
    /// Quiet labels: 3.6:1 on white, for short hints next to darker text.
    static let tertiary = adaptive(0.55, 0.54, 0.52, contrast: (0.36, 0.35, 0.34))
    static let red = Color(red: 1, green: 0.23, blue: 0.19)
    /// Success ticks and labels: 5:1 on white (the old 0.2/0.6/0.35 was 3.6:1).
    static let green = adaptive(0.13, 0.5, 0.27, contrast: (0.08, 0.38, 0.19))
    static let banner = Color(red: 0.1, green: 0.1, blue: 0.12)

    private static func adaptive(_ r: Double, _ g: Double, _ b: Double, contrast: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { _ in
            let c = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? contrast : (r, g, b)
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

enum Page: String, CaseIterable, Identifiable {
    case critiques = "Critiques"
    case guide = "Guide"
    case permissions = "Permissions"
    case connect = "Connect"
    case account = "Account"
    case storage = "Storage"
    case repos = "Repos"
    case agent = "Agent"
    case mobile = "Mobile"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .critiques: "text.bubble"
        case .guide: "keyboard"
        case .permissions: "lock.shield"
        case .connect: "point.3.connected.trianglepath.dotted"
        case .account: "person.crop.circle"
        case .storage: "internaldrive"
        case .repos: "arrow.triangle.branch"
        case .agent: "terminal"
        case .mobile: "iphone.gen3"
        }
    }
}

struct RootView: View {
    @ObservedObject var store: CritiqueStore
    let handoff: AgentHandoff
    @State private var page: Page = .critiques

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page)
                .frame(width: 220)
            Group {
                switch page {
                case .critiques: CritiquesPage(store: store, handoff: handoff)
                case .guide: GuidePage()
                case .permissions: PermissionsPage()
                case .connect: ConnectPage()
                case .account: AccountPage()
                case .storage: StoragePage(store: store)
                case .repos: ReposPage()
                case .agent: AgentPage()
                case .mobile: MobilePage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .padding(.top, 44)
            .padding([.trailing, .bottom], 10)
        }
        .background(Theme.sidebar)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .light)
        .ignoresSafeArea()
    }
}

struct Sidebar: View {
    @Binding var page: Page
    @ObservedObject private var projects = Projects.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LogoImage().frame(width: 26, height: 26)
                Text("Critique").font(.system(size: 20, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 58)
            .padding(.bottom, 22)

            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).frame(width: 20)
                        Text(item.rawValue)
                    }
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(page == item ? Theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            UpdateBanner() // only shows when a newer release is out

            VStack(alignment: .center, spacing: 10) {
                VStack(spacing: 3) {
                    Text("Start a critique").font(.system(size: 12, weight: .semibold))
                    if let project = projects.active {
                        Button { page = .agent } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                Text(project.name.split(separator: "/").last.map(String.init) ?? project.name).lineLimit(1)
                            }
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Critiques go to \(project.name). Change it on the Agent page.")
                    }
                }
                HStack(spacing: 6) {
                    KeyboardKey.backtick
                    Text("× 2").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                Text(verbatim: "Double-tap ` to start and send. Hold ` to draw.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
    }
}

/// Looks like a key on a Mac keyboard: symbol in the top corner, name at the bottom.
struct KeyboardKey: View {
    let name: String
    var symbol: String? = nil
    var width: CGFloat = 50

    static let option = KeyboardKey(name: "option", symbol: "⌥")
    static let control = KeyboardKey(name: "control", symbol: "⌃", width: 54)
    static let space = KeyboardKey(name: "space", width: 86)
    static let escape = KeyboardKey(name: "esc")
    static let backtick = KeyboardKey(name: "`")

    var body: some View {
        ZStack {
            // A darker edge under the key gives it a little depth, like a real keycap.
            RoundedRectangle(cornerRadius: 7).fill(Theme.border).offset(y: 2)
            RoundedRectangle(cornerRadius: 7).fill(Theme.panel)
            RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border)
            if name.count == 1 {
                Text(name).font(.system(size: 17, weight: .medium))
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(symbol ?? " ").font(.system(size: 11))
                    Spacer(minLength: 0)
                    Text(name).font(.system(size: 9.5, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: symbol == nil ? .center : .trailing)
            }
        }
        .foregroundStyle(Theme.ink)
        .frame(width: width, height: 38)
        .padding(.bottom, 2)
        .accessibilityLabel(name)
    }
}

/// Critique's mark: a magnifying glass with a red dot where you're pointing.
/// Drawn as vectors so it stays crisp at any size and matches the website.
struct LogoImage: View {
    var color: Color = Theme.ink

    var body: some View {
        Canvas { context, size in
            let u = min(size.width, size.height) / 32
            let lens = CGRect(x: 4.5 * u, y: 4.5 * u, width: 17 * u, height: 17 * u)
            context.stroke(Path(ellipseIn: lens), with: .color(color), lineWidth: 3 * u)
            var handle = Path()
            handle.move(to: CGPoint(x: 19.4 * u, y: 19.4 * u))
            handle.addLine(to: CGPoint(x: 27 * u, y: 27 * u))
            context.stroke(handle, with: .color(color), style: StrokeStyle(lineWidth: 3.4 * u, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 10.4 * u, y: 10.4 * u, width: 5.2 * u, height: 5.2 * u)), with: .color(Theme.red))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
