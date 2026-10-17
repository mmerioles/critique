import AppKit
import Combine
import SwiftUI

/// The small floating bar at the bottom of the screen — Critique's whole UI.
/// It never steals focus from the app you're testing (except while typing).
final class PillPanel: NSPanel {
    private let hosting: NSHostingView<PillView>
    private var observer: AnyCancellable?
    private weak var screenShown: NSScreen?

    @MainActor
    init(session: Session, onSubmitTyping: @escaping () -> Void) {
        hosting = NSHostingView(rootView: PillView(session: session, onSubmit: onSubmitTyping))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) // above the highlight overlay
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = hosting
        observer = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    override var canBecomeKey: Bool { true }

    func show(on screen: NSScreen) {
        screenShown = screen
        fit()
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }

    /// Gives keyboard focus back to the app underneath without hiding the bar.
    func releaseFocus() {
        guard isKeyWindow else { return }
        orderOut(nil)
        orderFrontRegardless()
    }

    private func fit() {
        guard let screen = screenShown ?? NSScreen.main else { return }
        let size = hosting.fittingSize
        let area = screen.visibleFrame
        setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 28, width: size.width, height: size.height),
                 display: true)
    }
}

struct PillView: View {
    @ObservedObject var session: Session
    var onSubmit: () -> Void
    @FocusState private var typingFocused: Bool

    var body: some View {
        Group {
            switch session.mode {
            case .sent(let detail):
                card { status(icon: "checkmark.circle.fill", tint: .green, title: "Sent to your agent", detail: detail) }
            case .notice(let text):
                card { status(icon: "sparkles", tint: .red, title: "Critique", detail: text) }
            case .typing:
                card { typing }
            default:
                pill
            }
        }
        .padding(12) // room for the shadow
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    /// While listening: recording dot, live waveform of your voice, timer, capture count.
    private var pill: some View {
        HStack(spacing: 10) {
            if session.isDrawing {
                Image(systemName: "pencil.tip").font(.system(size: 12, weight: .bold)).foregroundStyle(.red)
            } else {
                RecordingDot()
            }
            Waveform(levels: session.levels)
            TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(session.startedAt)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if session.shots.count > 1 {
                HStack(spacing: 3) {
                    Image(systemName: "viewfinder")
                    Text("\(session.shots.count - 1)")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule().fill(Color.black.opacity(0.9)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .animation(.spring(duration: 0.25), value: session.shots.count)
    }

    /// Only when the microphone isn't available.
    private var typing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Microphone is off — type your feedback").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("What do you see?", text: $session.committed, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...6)
                .focused($typingFocused)
                .onSubmit(onSubmit)
                .onAppear { typingFocused = true }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 400, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func status(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Bars that scroll with your voice, so you can see the mic is picking you up.
struct Waveform: View {
    var levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2.5, height: 3 + 20 * CGFloat(levels[i]))
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.05), value: levels)
    }
}

struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
