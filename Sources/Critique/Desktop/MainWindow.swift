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

enum Theme {
    static let sidebar = Color(red: 0.965, green: 0.957, blue: 0.945)   // warm off-white
    static let panel = Color.white
    static let border = Color(red: 0.91, green: 0.9, blue: 0.88)
    static let selected = Color(red: 0.925, green: 0.914, blue: 0.894)
    static let hover = Color(red: 0.98, green: 0.976, blue: 0.968)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let secondary = Color(red: 0.47, green: 0.46, blue: 0.44)
    static let tertiary = Color(red: 0.64, green: 0.63, blue: 0.61)
    static let red = Color(red: 1, green: 0.23, blue: 0.19)
    static let banner = Color(red: 0.1, green: 0.1, blue: 0.12)
}

enum Page: String, CaseIterable, Identifiable {
    case critiques = "Critiques"
    case guide = "Guide"
    case permissions = "Permissions"
    case connect = "Connect"
    case account = "Account"
    case storage = "Storage"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .critiques: "text.bubble"
        case .guide: "keyboard"
        case .permissions: "lock.shield"
        case .connect: "point.3.connected.trianglepath.dotted"
        case .account: "person.crop.circle"
        case .storage: "internaldrive"
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

            VStack(alignment: .center, spacing: 10) {
                Text("Start a critique").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    KeyboardKey.option
                    Text("× 2").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                Text("Double-tap right option, then talk. Hold ` to draw.")
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
