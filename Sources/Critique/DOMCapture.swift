import AppKit
import Foundation
import Network

/// One element the browser extension found inside a drawing on a web page.
struct DOMElement: Codable {
    var tag: String
    var id: String?
    var classes: [String]?
    /// A short CSS selector that matches only this element
    var selector: String?
    /// data-testid / data-test / data-cy value, and which attribute it came from
    var testId: String?
    var testAttr: String?
    /// Explicit role attribute
    var role: String?
    var ariaLabel: String?
    /// Visible text, trimmed to 80 characters (a field's placeholder, never its value)
    var text: String?
    var href: String?
    var name: String?
    var type: String?
    /// x, y, width, height in CSS px, relative to the page's viewport
    var rect: [Int]?
    var interactive: Bool?
    /// React, Vue, Svelte or Angular
    var framework: String?
    /// Nearest named component, e.g. SignupButton
    var component: String?
    /// The components above it, nearest first
    var parents: [String]?
    /// Source file and line in dev builds, e.g. src/components/Signup.tsx:42
    var source: String?
}

/// The web page a drawing was on.
struct DOMPage: Codable {
    var url: String
    var title: String?
}

/// Talks to the Critique browser extension (browser-extension/). The extension keeps a
/// WebSocket open to this server; when you draw on a browser window, Critique asks it
/// which DOM elements are under the drawing, so the agent gets selectors, test ids and
/// component names instead of just `button “Sign up”`.
///
/// Loopback only, and only `chrome-extension://` / `moz-extension://` origins may connect.
@MainActor
final class DOMCapture: ObservableObject {
    static let shared = DOMCapture()
    nonisolated static let port: UInt16 = 48213

    /// What the extension found for one drawing.
    struct Snapshot {
        let page: DOMPage
        let elements: [DOMElement]
        /// False when the extension's browser had no window under the drawing and guessed.
        let matched: Bool
    }

    /// Browsers whose extension is connected, e.g. ["Google Chrome"].
    @Published private(set) var browsers: [String] = []
    var isConnected: Bool { !browsers.isEmpty }

    private var listener: NWListener?
    private var links: [ObjectIdentifier: Link] = [:]
    private var pending: [String: Pending] = [:]
    private let queue = DispatchQueue(label: "dev.critique.dom")

    // MARK: Asking

    /// The DOM elements inside `rect` (global, top-left origin, in points), or nil when no
    /// extension is connected or none answered within 300 ms.
    func elements(in rect: CGRect, hint: String?) async -> [DOMElement]? {
        await snapshot(in: rect, hint: hint, scale: NSScreen.main?.backingScaleFactor ?? 2)?.elements
    }

    /// Like `elements(in:hint:)`, but only when `app` is a browser the extension runs in,
    /// and with the page URL too.
    func snapshot(in rect: CGRect, hint: String?, app: String?, scale: CGFloat) async -> Snapshot? {
        guard Self.isBrowser(app: app) else { return nil }
        return await snapshot(in: rect, hint: hint, scale: scale)
    }

    func snapshot(in rect: CGRect, hint: String?, scale: CGFloat) async -> Snapshot? {
        let ready = links.values.filter(\.ready)
        guard !ready.isEmpty else { return nil }
        let id = UUID().uuidString
        let request = Request(id: id, screen: .init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height),
                              scale: Double(scale), hint: hint)
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        let started = Date()
        let result: Snapshot? = await withCheckedContinuation { continuation in
            pending[id] = Pending(remaining: ready.count, continuation: continuation)
            for link in ready { link.send(data) }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                pending.removeValue(forKey: id)?.finish()
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let result {
            log("dom: \(result.elements.count) element(s) on \(result.page.url) in \(ms) ms")
        } else {
            log("dom: no answer from the browser extension in \(ms) ms")
        }
        return result
    }

    /// Apps whose windows are web pages the extension can inspect. Safari isn't one.
    nonisolated static func isBrowser(app name: String?, bundleID: String? = nil) -> Bool {
        if let bundleID, browserBundleIDs.contains(where: { bundleID.hasPrefix($0) }) { return true }
        guard let name = name?.lowercased() else { return false }
        if name == "arc" { return true }
        return ["google chrome", "chrome", "chromium", "brave", "microsoft edge", "firefox", "vivaldi", "opera"]
            .contains { name.hasPrefix($0) }
    }

    nonisolated static let browserBundleIDs = [
        "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// The extension's folder, to load unpacked: bundled in the app if `make app` put it
    /// there, otherwise next to the source checkout the binary was built from.
    nonisolated static var extensionFolder: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("browser-extension")) }
        if var dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("browser-extension"))
                dir.deleteLastPathComponent()
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    // MARK: Server

    /// Starts listening on 127.0.0.1:48213. Safe to call more than once.
    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        // Only a browser extension may connect — not a web page, not another process.
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let allowed = Self.allowedOrigins.contains { origin.lowercased().hasPrefix($0) }
            if !allowed { log("dom: refused a WebSocket from origin “\(origin)”") }
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            log("dom: can't listen on 127.0.0.1:\(Self.port): \(error.localizedDescription)")
            retryLater()
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log("dom: listening on 127.0.0.1:\(Self.port) for the browser extension")
            case .failed(let error):
                log("dom: listener failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in self?.restart() }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for link in links.values { link.close() }
        links = [:]
        browsers = []
    }

    nonisolated private static let allowedOrigins = ["chrome-extension://", "moz-extension://"]
    nonisolated private static let debug = ProcessInfo.processInfo.environment["CRITIQUE_DOM_DEBUG"] != nil

    private func restart() {
        listener?.cancel()
        listener = nil
        retryLater()
    }

    private func retryLater() {
        Task {
            try? await Task.sleep(for: .seconds(10))
            start()
        }
    }

    private func accept(_ connection: NWConnection) {
        let link = Link(connection) { [weak self] link, event in self?.handle(event, from: link) }
        links[ObjectIdentifier(link)] = link
        link.start(on: queue)
    }

    private func handle(_ event: Link.Event, from link: Link) {
        switch event {
        case .ready:
            link.ready = true
            refresh()
        case .closed:
            if links.removeValue(forKey: ObjectIdentifier(link)) != nil, link.ready {
                log("dom: \(link.browser ?? "browser") extension disconnected")
            }
            refresh()
        case .message(let data):
            // CRITIQUE_DOM_DEBUG=1 logs everything the extension sends, for "why no DOM lines?".
            if Self.debug { log("dom: ← \(String(decoding: data.prefix(4000), as: UTF8.self))") }
            guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
            switch message.type {
            case "hello":
                link.browser = message.browser
                log("dom: \(message.browser ?? "browser") extension \(message.version ?? "") connected")
                refresh()
            case "ping":
                link.send(Data(#"{"type":"pong"}"#.utf8))
            case "elements":
                if let id = message.id { resolve(id, message, from: link) }
            default:
                break
            }
        }
    }

    private func refresh() {
        var names: [String] = []
        for link in links.values where link.ready {
            let name = link.browser ?? "Browser"
            if !names.contains(name) { names.append(name) }
        }
        names.sort()
        if names != browsers { browsers = names }
    }

    private func resolve(_ id: String, _ message: Message, from link: Link) {
        guard let request = pending[id] else { return }
        request.remaining -= 1
        if let error = message.error {
            log("dom: \(link.browser ?? "browser"): \(error)")
        } else if let url = message.url {
            let snapshot = Snapshot(page: DOMPage(url: url, title: message.title),
                                    elements: message.elements ?? [], matched: message.matched ?? true)
            if request.best.map({ Self.better(snapshot, than: $0) }) ?? true { request.best = snapshot }
            // The browser under the drawing answered with something: no need to wait for the others.
            if snapshot.matched, !snapshot.elements.isEmpty {
                pending.removeValue(forKey: id)?.finish()
                return
            }
        }
        if request.remaining <= 0 { pending.removeValue(forKey: id)?.finish() }
    }

    private static func better(_ a: Snapshot, than b: Snapshot) -> Bool {
        if a.matched != b.matched { return a.matched }
        return a.elements.count > b.elements.count
    }

    // MARK: Wire format

    private struct Request: Encodable {
        struct Rect: Encodable { var x, y, w, h: Double }
        var type = "elements"
        var id: String
        /// Global screen points, top-left origin
        var screen: Rect
        /// The display's backing scale factor
        var scale: Double
        /// What Accessibility saw there, e.g. `button “Sign up”`
        var hint: String?
    }

    private struct Message: Decodable {
        var type: String
        var id: String?
        var browser: String?
        var version: String?
        var url: String?
        var title: String?
        var matched: Bool?
        var error: String?
        var elements: [DOMElement]?
    }

    /// One drawing waiting for the extensions' answers.
    private final class Pending {
        var remaining: Int
        var best: Snapshot?
        private var continuation: CheckedContinuation<Snapshot?, Never>?

        init(remaining: Int, continuation: CheckedContinuation<Snapshot?, Never>) {
            self.remaining = remaining
            self.continuation = continuation
        }

        func finish() {
            continuation?.resume(returning: best)
            continuation = nil
        }
    }

    /// One connected extension. Network callbacks run on the queue and hop to the main actor.
    /// Unchecked: `browser` and `ready` are only touched on the main actor; NWConnection is thread-safe.
    private final class Link: @unchecked Sendable {
        enum Event { case ready, message(Data), closed }

        let connection: NWConnection
        // Main actor only.
        var browser: String?
        var ready = false
        private let onEvent: @MainActor @Sendable (Link, Event) -> Void

        init(_ connection: NWConnection, onEvent: @escaping @MainActor @Sendable (Link, Event) -> Void) {
            self.connection = connection
            self.onEvent = onEvent
        }

        func start(on queue: DispatchQueue) {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.emit(.ready)
                    self.receive()
                case .failed, .cancelled:
                    self.emit(.closed)
                default: break
                }
            }
            connection.start(queue: queue)
        }

        func send(_ data: Data) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }

        func close() { connection.cancel() }

        private func receive() {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self else { return }
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .close:
                        self.connection.cancel()
                        return
                    case .text, .binary:
                        if let data, !data.isEmpty { self.emit(.message(data)) }
                    default: break
                    }
                }
                if error != nil {
                    self.connection.cancel()
                    return
                }
                self.receive()
            }
        }

        private func emit(_ event: Event) {
            let onEvent = onEvent
            Task { @MainActor in onEvent(self, event) }
        }
    }
}
