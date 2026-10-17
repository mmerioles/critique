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
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .critiques: "text.bubble"
        case .guide: "keyboard"
        case .permissions: "lock.shield"
        case .connect: "point.3.connected.trianglepath.dotted"
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
                    Label(item.rawValue, systemImage: item.icon)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Start a critique").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 4) {
                    KeyCap("right ⌥")
                    Text("×2").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Text("Talk and point. Hold ` to draw.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
    }
}

struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
    }
}

struct LogoImage: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "magnifyingglass").resizable().aspectRatio(contentMode: .fit)
        }
    }
}
