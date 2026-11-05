import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A tiny MCP server (JSON-RPC over stdio) that hands Critique feedback —
/// your words plus screenshots — straight to a coding agent.
///
///   claude mcp add critique -- /Applications/Critique.app/Contents/MacOS/Critique mcp
///
/// Every file of a critique is a resource at critique://inbox/<id>/<file>. Tool results
/// link to them instead of inlining everything, so one call can't swamp the agent's
/// context; only the newest critique's annotated screenshots come inline.
enum MCPServer {
    private static let output = DispatchQueue(label: "critique.mcp.output")
    private static let work = DispatchQueue(label: "critique.mcp.work", attributes: .concurrent)
    private static let scheme = "critique://inbox/"
    /// How many images get_feedback inlines per call.
    private static let maxInline = 6
    /// How many critiques resources/list covers.
    private static let listed = 10

    struct RPCError: Error {
        var code: Int
        var message: String
        var data: [String: Any]? = nil
    }

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
        guard let method = message["method"] as? String else { return } // a response to something we sent
        guard let id = message["id"] else { return } // notification (e.g. notifications/initialized): nothing to say back
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:], "resources": [:]],
                    "serverInfo": ["name": "critique", "version": "0.1.0"],
                    "instructions": "Critique lets the user give UI feedback by talking over their screen. "
                        + "Call get_feedback to read it: their words as markdown, the newest critique's annotated screenshots inline, "
                        + "and critique:// resource links for every screenshot, zoomed crop, recording frame, voice and screen recording "
                        + "(read one with resources/read, or get_image for a picture). "
                        + "Nothing is marked read until you call acknowledge_feedback with the ids — do that once you've implemented the feedback. "
                        + "Call wait_for_feedback to wait for their next round while iterating.",
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let args = params["arguments"] as? [String: Any] ?? [:]
                reply(id, result: try call(params["name"] as? String ?? "", args))
            case "resources/list":
                reply(id, result: ["resources": resources()])
            case "resources/templates/list":
                reply(id, result: ["resourceTemplates": [[
                    "uriTemplate": "critique://inbox/{id}/{file}",
                    "name": "Critique file",
                    "title": "A file from one critique",
                    "description": "A file of one critique by its id (from list_feedback or get_feedback): feedback.md, feedback.json, "
                        + "a screenshot such as 1-drawing.png, a zoomed crop, a recording frame such as frames/0-01.8.jpg, voice.m4a or recording.mov.",
                ]]])
            case "resources/read":
                reply(id, result: ["contents": [try read(params["uri"] as? String ?? "")]])
            default:
                throw RPCError(code: -32601, message: "Method not found: \(method)")
            }
        } catch let error as RPCError {
            fail(id, error)
        } catch {
            fail(id, RPCError(code: -32603, message: error.localizedDescription))
        }
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "get_feedback",
            "description": "Get UX feedback the user recorded with Critique: what they said while looking at their screen, plus screenshots with the parts they highlighted. "
                + "Returns every unacknowledged critique for this project (oldest first), or the latest if all are acknowledged. "
                + "Each critique is markdown followed by resource_link blocks (critique://inbox/<id>/<file>) for its screenshots, zoomed crops, recording frames, voice and screen recording; "
                + "read one with resources/read or get_image. The newest critique's annotated screenshots are also inlined (at most 6 images). "
                + "Nothing is marked read: call acknowledge_feedback with the ids once you've implemented it. Pass an id to get a specific one.",
            "inputSchema": ["type": "object", "properties": [
                "id": ["type": "string", "description": "Feedback id from list_feedback (optional)"],
                "inline_images": ["type": "boolean", "description": "true (default): inline the newest critique's annotated screenshots, up to 6. false: links only."],
            ]],
        ],
        [
            "name": "wait_for_feedback",
            "description": "Wait for the user's next piece of UX feedback (they double-tap the ` key, talk, highlight, and send). Use after making changes so they can review and respond. "
                + "Returns the feedback in the same shape as get_feedback (it is not marked read — acknowledge it when done), or a timeout message.",
            "inputSchema": ["type": "object", "properties": [
                "timeout_seconds": ["type": "number", "description": "How long to wait. Default 600."],
                "inline_images": ["type": "boolean", "description": "Same as get_feedback. Default true."],
            ]],
        ],
        [
            "name": "acknowledge_feedback",
            "description": "Mark critiques as read once you've implemented them (or decided not to). Until then get_feedback keeps returning them and the Critique app shows them as unread.",
            "inputSchema": ["type": "object", "properties": [
                "ids": ["type": "array", "items": ["type": "string"], "description": "Feedback ids to mark read"],
            ], "required": ["ids"]],
        ],
        [
            "name": "get_image",
            "description": "Return one Critique image inline (as a downscaled JPEG) by its critique:// uri from get_feedback — for clients that can't read resources. "
                + "Works for screenshots, zoomed crops and recording frames.",
            "inputSchema": ["type": "object", "properties": [
                "uri": ["type": "string", "description": "critique://inbox/<id>/<file>"],
                "max_pixels": ["type": "integer", "description": "Longest side in pixels. Default 1568."],
            ], "required": ["uri"]],
        ],
        [
            "name": "list_feedback",
            "description": "List recent Critique feedback with ids, times, and whether it has been acknowledged.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ]

    private static func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        let inline = args["inline_images"] as? Bool ?? true
        switch name {
        case "get_feedback":
            if let id = args["id"] as? String {
                guard let dir = folder(id), InboxIndex.entry(for: dir) != nil else { return text("No feedback with id \(id).") }
                return content(for: [dir], inline: inline)
            }
            let all = Inbox.items()
            let unread = all.filter { !Inbox.isSeen($0) && isForThisProject($0) }.reversed()
            if !unread.isEmpty { return content(for: Array(unread), inline: inline) }
            if let latest = all.first(where: { InboxIndex.entry(for: $0) != nil }) {
                return content(for: [latest], note: "No unacknowledged feedback — here is the latest (already acknowledged).", inline: inline)
            }
            return text("No feedback yet. Ask the user to double-tap the ` key, describe what they see, and double-tap again to send.")

        case "wait_for_feedback":
            let timeout = min(max((args["timeout_seconds"] as? Double) ?? 600, 1), 3600)
            let deadline = Date().addingTimeInterval(timeout)
            let watcher = InboxWatcher()
            defer { watcher.cancel() }
            // Anything readable now is old news; a folder still being written counts as new once it decodes.
            let known = Set(Inbox.items().filter { InboxIndex.entry(for: $0) != nil }.map(\.lastPathComponent))
            let fresh = watcher.wait(until: deadline) {
                var found: [URL] = [], pending = false
                for dir in folders() where !known.contains(dir.lastPathComponent) {
                    guard InboxIndex.entry(for: dir) != nil else {
                        // Half written: watch the folder (and the JSON once it appears) so we wake when it lands.
                        pending = true
                        watcher.watch(dir)
                        let json = dir.appendingPathComponent("feedback.json")
                        if FileManager.default.fileExists(atPath: json.path) { watcher.watch(json) }
                        continue
                    }
                    if !Inbox.isSeen(dir), isForThisProject(dir) { found.append(dir) }
                }
                return (found.sorted { $0.lastPathComponent < $1.lastPathComponent }, pending)
            }
            if !fresh.isEmpty { return content(for: fresh, inline: inline) }
            return text("No new feedback after \(Int(timeout))s. The user may still be looking — you can wait again.")

        case "acknowledge_feedback":
            guard let ids = args["ids"] as? [String], !ids.isEmpty else {
                return ["isError": true, "content": [["type": "text", "text": "Pass ids: an array of feedback ids."]]]
            }
            var done: [String] = [], unknown: [String] = []
            for id in ids {
                if let dir = folder(id), InboxIndex.entry(for: dir) != nil {
                    Inbox.markSeen(dir)
                    done.append(id)
                } else {
                    unknown.append(id)
                }
            }
            var lines: [String] = []
            if !done.isEmpty { lines.append("Acknowledged \(done.count): \(done.joined(separator: ", ")).") }
            if !unknown.isEmpty { lines.append("No feedback with id: \(unknown.joined(separator: ", ")).") }
            return text(lines.joined(separator: "\n"))

        case "get_image":
            guard let uri = args["uri"] as? String, let file = locate(uri) else {
                return ["isError": true, "content": [["type": "text", "text": "No such image. Pass a critique://inbox/<id>/<file> uri from get_feedback."]]]
            }
            let maxPixels = min(max((args["max_pixels"] as? Int) ?? 1568, 64), 4096)
            guard mime(for: file.url).hasPrefix("image/"), let data = jpeg(file.url, maxPixels: maxPixels) else {
                return ["isError": true, "content": [["type": "text", "text": "\(file.id)/\(file.name) is not an image I can read."]]]
            }
            return ["content": [
                ["type": "text", "text": "\(file.id)/\(file.name):"],
                ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"],
            ]]

        case "list_feedback":
            let rows = Inbox.items().prefix(20).compactMap { dir -> String? in
                guard let r = Inbox.load(dir) else { return nil }
                let first = r.notes.split(separator: "\n").first.map(String.init) ?? "(highlights only)"
                return "- \(r.id) · \(Inbox.isSeen(dir) ? "acknowledged" : "UNREAD") · \(r.shots.count) screenshot(s) · \(first.prefix(80))"
            }
            return text(rows.isEmpty ? "No feedback yet." : rows.joined(separator: "\n"))

        default:
            throw RPCError(code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: - Inbox

    /// Every folder in the inbox, whether or not its feedback.json has landed yet.
    private static func folders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Inbox.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// The folder for an id, as long as the id is a plain folder name.
    private static func folder(_ id: String) -> URL? {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.hasPrefix(".") else { return nil }
        return Inbox.root.appendingPathComponent(id)
    }

    private static let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
    private static let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path

    /// Critiques tagged for another project are left for the agent working in that project.
    /// Untagged ones, or when the agent isn't in a project folder, go to anyone.
    private static func isForThisProject(_ dir: URL) -> Bool {
        guard let path = InboxIndex.entry(for: dir)?.project else { return true }
        guard cwd != "/", cwd != home else { return true }
        let project = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return cwd == project || cwd.hasPrefix(project + "/") || project.hasPrefix(cwd + "/")
    }

    // MARK: - Tool content

    /// Markdown for each item and links to its files. The newest item's annotated
    /// screenshots come inline too (when `inline`), up to `maxInline` images.
    private static func content(for dirs: [URL], note: String? = nil, inline: Bool) -> [String: Any] {
        var blocks: [[String: Any]] = []
        if let note { blocks.append(["type": "text", "text": note]) }
        var ids: [String] = []
        for (index, dir) in dirs.enumerated() {
            guard let record = Inbox.load(dir) else { continue }
            ids.append(dir.lastPathComponent)
            blocks.append(["type": "text", "text": record.markdown(in: dir)])
            if inline, index == dirs.count - 1 {
                // Marked-up screenshots first, then their zoomed crops (older critiques only had an opening screenshot).
                var shots = record.shots.filter { $0.kind != "screen" }
                if shots.isEmpty { shots = record.shots }
                let files = shots.map { ($0.number, $0.file, "") }
                    + shots.compactMap { shot in shot.zoomFile.map { (shot.number, $0, " (zoomed)") } }
                for (number, file, suffix) in files.prefix(maxInline) {
                    guard let data = jpeg(dir.appendingPathComponent(file)) else { continue }
                    blocks.append(["type": "text", "text": "Screenshot #\(number)\(suffix):"])
                    blocks.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                }
            }
            for file in files(of: record, in: dir) where file.name != "feedback.md" && file.name != "feedback.json" {
                blocks.append([
                    "type": "resource_link",
                    "uri": scheme + dir.lastPathComponent + "/" + file.name,
                    "name": file.name,
                    "description": file.description,
                    "mimeType": file.mimeType,
                ])
            }
        }
        if !ids.isEmpty {
            blocks.append(["type": "text", "text": "Linked files are resources: read one with resources/read, or get_image for a picture. "
                + "Once you've implemented this, call acknowledge_feedback with ids: [\(ids.map { "\"\($0)\"" }.joined(separator: ", "))]."])
        }
        return ["content": blocks]
    }

    // MARK: - Resources

    struct File {
        var name: String
        var description: String
        var mimeType: String
    }

    /// The files of one critique, in reading order. Only ones that exist on disk.
    private static func files(of record: FeedbackRecord, in dir: URL) -> [File] {
        var all: [File] = [
            File(name: "feedback.md", description: "The critique as markdown: what they said, the timeline, and where each file is.", mimeType: "text/markdown"),
            File(name: "feedback.json", description: "The critique, structured.", mimeType: "application/json"),
        ]
        for shot in record.shots {
            var what = "Screenshot #\(shot.number): \(FeedbackRecord.label(shot.kind).lowercased())"
            if let element = shot.element { what += " \(element)" }
            if let app = shot.app { what += " · \(app)" }
            all.append(File(name: shot.file, description: what, mimeType: mime(for: shot.file)))
            if let zoom = shot.zoomFile {
                all.append(File(name: zoom, description: "Screenshot #\(shot.number), zoomed in on what they marked", mimeType: mime(for: zoom)))
            }
        }
        for moment in record.timeline ?? [] {
            guard let frame = moment.frame else { continue }
            all.append(File(name: frame, description: "Recording frame at \(FeedbackRecord.clock(moment.at, tenths: true)) (\(moment.kind) \(moment.text.prefix(60)))", mimeType: mime(for: frame)))
        }
        if let audio = record.audio {
            all.append(File(name: audio, description: "Their voice, \(FeedbackRecord.clock(record.duration ?? 0))", mimeType: mime(for: audio)))
        }
        if let video = record.video {
            all.append(File(name: video, description: "Screen recording with their voice, \(FeedbackRecord.clock(record.duration ?? 0))", mimeType: mime(for: video)))
        }
        return all.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.name).path) }
    }

    /// Files of the newest critiques, for resources/list.
    private static func resources() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for dir in Inbox.items().prefix(listed) {
            guard let record = Inbox.load(dir) else { continue }
            let id = dir.lastPathComponent
            for file in files(of: record, in: dir) {
                var entry: [String: Any] = [
                    "uri": scheme + id + "/" + file.name,
                    "name": id + "/" + file.name,
                    "title": "\(FeedbackRecord.displayDate.string(from: record.createdAt)) · \(file.name)",
                    "description": file.description,
                    "mimeType": file.mimeType,
                ]
                if let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.name).path))?[.size] as? Int {
                    entry["size"] = size
                }
                out.append(entry)
            }
        }
        return out
    }

    /// One resource's contents: text for markdown and JSON, base64 blob for everything else.
    private static func read(_ uri: String) throws -> [String: Any] {
        guard let file = locate(uri), let data = try? Data(contentsOf: file.url) else {
            throw RPCError(code: -32002, message: "Resource not found", data: ["uri": uri])
        }
        let mimeType = mime(for: file.url)
        if mimeType.hasPrefix("text/") || mimeType == "application/json", let text = String(data: data, encoding: .utf8) {
            return ["uri": uri, "mimeType": mimeType, "text": text]
        }
        return ["uri": uri, "mimeType": mimeType, "blob": data.base64EncodedString()]
    }

    /// Resolves critique://inbox/<id>/<file> to a regular file inside that critique's folder, or nil.
    private static func locate(_ uri: String) -> (id: String, name: String, url: URL)? {
        guard uri.hasPrefix(scheme) else { return nil }
        let rest = uri.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let id = String(rest[..<slash]), name = String(rest[rest.index(after: slash)...])
        guard let dir = folder(id), !name.isEmpty else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else { return nil }
        let url = dir.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return (id, name, url)
    }

    private static func mime(for url: URL) -> String { mime(for: url.lastPathComponent) }

    private static func mime(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "txt": return "text/plain"
        case "m4a": return "audio/mp4"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Plumbing

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

    private static func fail(_ id: Any, _ error: RPCError) {
        var body: [String: Any] = ["code": error.code, "message": error.message]
        if let data = error.data { body["data"] = data }
        send(["jsonrpc": "2.0", "id": id, "error": body])
    }

    private static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        output.sync { FileHandle.standardOutput.write(data) }
    }
}
