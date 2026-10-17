import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A tiny MCP server (JSON-RPC over stdio) that hands UX Flow feedback —
/// your words plus screenshots — straight to a coding agent.
///
///   claude mcp add uxflow -- /Applications/UXFlow.app/Contents/MacOS/UXFlow mcp
enum MCPServer {
    private static let output = DispatchQueue(label: "uxflow.mcp.output")
    private static let work = DispatchQueue(label: "uxflow.mcp.work", attributes: .concurrent)

    static func run() -> Never {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Tool calls may block (wait_for_feedback), so they run off the read loop.
            work.async { handle(message) }
        }
        exit(0)
    }

    private static func handle(_ message: [String: Any]) {
        guard let id = message["id"], let method = message["method"] as? String else { return } // notification
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            reply(id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "uxflow", "version": "0.1.0"],
                "instructions": "UX Flow lets the user give UI feedback by talking over their screen. "
                    + "Call get_feedback to read it (notes + annotated screenshots). "
                    + "Call wait_for_feedback to wait for their next round while iterating.",
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": tools])
        case "tools/call":
            let args = params["arguments"] as? [String: Any] ?? [:]
            reply(id, result: call(params["name"] as? String ?? "", args))
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "get_feedback",
            "description": "Get UX feedback the user recorded with UX Flow: what they said while looking at their screen, plus screenshots with the parts they highlighted. Returns all unread feedback (oldest first), or the latest if everything has been read. Pass an id to get a specific one.",
            "inputSchema": ["type": "object", "properties": [
                "id": ["type": "string", "description": "Feedback id from list_feedback (optional)"],
            ]],
        ],
        [
            "name": "wait_for_feedback",
            "description": "Wait for the user's next piece of UX feedback (they double-tap right Option, talk, highlight, and send). Use after making changes so they can review and respond. Returns the feedback, or a timeout message.",
            "inputSchema": ["type": "object", "properties": [
                "timeout_seconds": ["type": "number", "description": "How long to wait. Default 600."],
            ]],
        ],
        [
            "name": "list_feedback",
            "description": "List recent UX Flow feedback with ids, times, and whether it has been read.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ]

    private static func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        switch name {
        case "get_feedback":
            if let id = args["id"] as? String {
                let dir = Inbox.root.appendingPathComponent(id)
                return Inbox.load(dir) == nil ? text("No feedback with id \(id).") : content(for: [dir])
            }
            let all = Inbox.items()
            let unread = all.filter { !Inbox.isSeen($0) }.reversed()
            if !unread.isEmpty { return content(for: Array(unread)) }
            if let latest = all.first { return content(for: [latest], note: "No unread feedback — here is the latest (already read).") }
            return text("No feedback yet. Ask the user to double-tap right Option, describe what they see, and double-tap again to send.")

        case "wait_for_feedback":
            let timeout = min(max((args["timeout_seconds"] as? Double) ?? 600, 1), 3600)
            let deadline = Date().addingTimeInterval(timeout)
            let known = Set(Inbox.items().map(\.lastPathComponent))
            while Date() < deadline {
                let fresh = Inbox.items().filter { !known.contains($0.lastPathComponent) && !Inbox.isSeen($0) }
                if !fresh.isEmpty { return content(for: fresh.reversed()) }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return text("No new feedback after \(Int(timeout))s. The user may still be looking — you can wait again.")

        case "list_feedback":
            let rows = Inbox.items().prefix(20).compactMap { dir -> String? in
                guard let r = Inbox.load(dir) else { return nil }
                let first = r.notes.split(separator: "\n").first.map(String.init) ?? "(highlights only)"
                return "- \(r.id) · \(Inbox.isSeen(dir) ? "read" : "UNREAD") · \(r.shots.count) screenshot(s) · \(first.prefix(80))"
            }
            return text(rows.isEmpty ? "No feedback yet." : rows.joined(separator: "\n"))

        default:
            return ["isError": true, "content": [["type": "text", "text": "Unknown tool: \(name)"]]]
        }
    }

    /// Markdown for each item, followed by its screenshots as images. Marks them read.
    private static func content(for dirs: [URL], note: String? = nil) -> [String: Any] {
        var blocks: [[String: Any]] = []
        if let note { blocks.append(["type": "text", "text": note]) }
        for dir in dirs {
            guard let record = Inbox.load(dir) else { continue }
            blocks.append(["type": "text", "text": record.markdown(in: dir)])
            for shot in record.shots {
                for file in [shot.file, shot.zoomFile].compactMap({ $0 }) {
                    if let data = jpeg(dir.appendingPathComponent(file)) {
                        blocks.append(["type": "text", "text": "Screenshot #\(shot.number)\(file == shot.zoomFile ? " (zoomed)" : ""):"])
                        blocks.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                    }
                }
            }
            // Frames from the screen recording, for moments no screenshot covers.
            for moment in (record.timeline ?? []).filter({ $0.frame != nil }).prefix(8) {
                if let data = jpeg(dir.appendingPathComponent(moment.frame!)) {
                    blocks.append(["type": "text", "text": "Recording frame at \(FeedbackRecord.clock(moment.at, tenths: true)) (\(moment.kind) \(moment.text.prefix(60))):"])
                    blocks.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                }
            }
            Inbox.markSeen(dir)
        }
        return ["content": blocks]
    }

    /// Downscaled JPEG so screenshots stay small enough for the model.
    private static func jpeg(_ url: URL, maxPixels: Int = 1568) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }

    private static func reply(_ id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        output.sync { FileHandle.standardOutput.write(data) }
    }
}
