import Combine
import Foundation
import Synchronization

/// Words from the project you're critiquing — component names, button labels,
/// routes, branch names — so dictation hears "SignupModal" rather than "sign up model".
///
/// Built in the background from the project's source files, and cached until a
/// source file changes. `current()` is what the speech recognizers get.
enum ProjectVocabulary {
    /// The strings for the project last prepared. Cheap, safe from any thread.
    static func current() -> [String] { state.withLock { $0.latest } }

    /// Builds the vocabulary for the active project in the background (a no-op
    /// when nothing changed since last time).
    static func prepare() {
        Task.detached(priority: .utility) {
            guard let record = Projects.activeRecord() else {
                state.withLock { $0.latest = [] }
                return
            }
            let path = record.path
            guard state.withLock({ $0.inFlight.insert(path).inserted }) else { return }
            defer { state.withLock { _ = $0.inFlight.remove(path) } }
            let strings = build(at: URL(fileURLWithPath: path), name: record.name)
            state.withLock { $0.latest = strings }
        }
    }

    /// Follows the project picked on the Repos page (and prepares the current one right away).
    @MainActor static func watch() {
        watching = Projects.shared.$active.sink { _ in prepare() }
    }

    // MARK: - Building

    /// What the build tasks and callers share, behind one lock.
    private struct State {
        var cache: [String: (key: String, strings: [String])] = [:]
        var latest: [String] = []
        var inFlight = Set<String>()
    }
    private static let state = Mutex(State())
    @MainActor private static var watching: AnyCancellable?

    private static let maxStrings = 150
    private static let maxLength = 40
    private static let maxFiles = 400
    private static let maxBytes = 4_000_000
    private static let maxFileBytes = 96_000

    private static let skippedFolders: Set<String> = ["node_modules", ".build", "build", "dist", ".git", "vendor", "Pods",
                                                       "DerivedData", "Carthage", "target", ".next", "out", "coverage",
                                                       "__pycache__", ".gradle"]
    private static let sourceExtensions: Set<String> = ["swift", "kt", "java", "ts", "tsx", "js", "jsx", "mjs", "vue", "svelte",
                                                         "dart", "py", "rb", "go", "rs", "cs", "m", "mm", "html", "xml", "strings"]

    /// Identifiers that are everywhere and never what you're talking about.
    private static let stoplist: Set<String> = [
        "string", "int", "bool", "double", "float", "void", "array", "dictionary", "set", "list", "map", "view", "text",
        "button", "color", "image", "date", "data", "error", "result", "option", "optional", "any", "some", "self",
        "this", "null", "nil", "true", "false", "return", "import", "export", "default", "const", "let", "var", "func",
        "function", "class", "struct", "enum", "async", "await", "throws", "static", "private", "public", "internal",
        "override", "super", "init", "deinit", "index", "value", "key", "item", "count", "name", "type", "url",
        "foundation", "uikit", "swiftui", "appkit", "react", "usestate", "useeffect", "usecallback", "usememo",
        "useref", "classname", "onclick", "onchange", "onsubmit", "console", "log", "props", "state", "document",
        "window", "require", "module", "exports", "main", "test", "tests", "package", "json", "http", "https", "path",
        "file", "files", "user", "users", "get", "set", "add", "remove", "update", "delete", "create", "new", "old",
        "min", "max", "src", "lib", "node", "npm", "div", "span", "none", "all", "with", "from", "for", "the", "and",
        "not", "use", "end", "start", "size", "width", "height", "frame", "body", "main", "object", "interface",
        "protocol", "extension", "typealias", "where", "guard", "else", "case", "switch", "while", "break", "continue",
        "number", "boolean", "undefined", "symbol", "readonly", "promise", "void", "never", "unknown", "android",
        "androidx", "kotlin", "java", "lang", "util", "apply", "also", "run", "when", "fun", "val", "override",
        "activity", "fragment", "context", "bundle", "intent", "weak", "lazy", "final", "mutating", "nonisolated",
        "mainactor", "sendable", "codable", "hashable", "equatable", "identifiable", "observableobject", "published",
        "cgfloat", "cgrect", "cgpoint", "cgsize", "nsstring", "uuid",
    ]

    /// Reads the project once (newest files first) and returns the best strings.
    private static func build(at root: URL, name: String) -> [String] {
        let started = Date()
        let files = sourceFiles(in: root)
        let newest = files.map(\.modified).max() ?? .distantPast
        let key = "\(files.count)-\(newest.timeIntervalSince1970)"
        if let cached = state.withLock({ $0.cache[root.path] }), cached.key == key { return cached.strings }

        var terms = Terms()
        var bytes = 0
        var read = 0
        for file in files {
            guard bytes < maxBytes else { break }
            guard let data = FileManager.default.contents(atPath: file.url.path) else { continue }
            let slice = data.count > maxFileBytes ? data.prefix(maxFileBytes) : data[...]
            guard let text = String(data: slice, encoding: .utf8) else { continue }
            bytes += slice.count
            read += 1
            scan(text, of: file.url, into: &terms)
        }
        branches(in: root, into: &terms)
        let strings = terms.ranked(limit: maxStrings)
        state.withLock { $0.cache[root.path] = (key, strings) }
        log("project vocabulary: \(strings.count) strings from \(read) files in \(name) (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        return strings
    }

    private struct SourceFile {
        let url: URL
        let modified: Date
    }

    /// Source files worth reading, newest first, skipping dependencies and build output.
    private static func sourceFiles(in root: URL) -> [SourceFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .nameKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [SourceFile] = []
        var visited = 0
        for case let url as URL in walk {
            visited += 1
            if visited > 20_000 { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if skippedFolders.contains(values.name ?? url.lastPathComponent) { walk.skipDescendants() }
                continue
            }
            let name = url.lastPathComponent
            guard sourceExtensions.contains(url.pathExtension.lowercased()) || name == "package.json" else { continue }
            if url.pathExtension == "xml", name != "strings.xml" { continue } // only Android's UI strings
            if name.hasSuffix(".min.js") || name.hasSuffix(".d.ts") || name.hasSuffix("-lock.json") { continue }
            files.append(SourceFile(url: url, modified: values.contentModificationDate ?? .distantPast))
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(maxFiles))
    }

    // MARK: Extraction

    /// Scores terms by how often they show up and how likely they are to be said aloud.
    private struct Terms {
        private var count: [String: Int] = [:]
        private var weight: [String: Double] = [:]
        private var display: [String: String] = [:]

        /// `weight` says how UI-like the term is (4 = a label on screen, 1 = any identifier).
        mutating func add(_ raw: String, weight w: Double) {
            let term = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard term.count >= 2, term.count <= ProjectVocabulary.maxLength,
                  term.filter(\.isLetter).count >= 2, !term.contains(where: { $0 == "\\" || $0 == "<" || $0 == ">" }) else { return }
            let key = term.lowercased()
            guard !ProjectVocabulary.stoplist.contains(key) else { return }
            if term.count < 3 && term != term.uppercased() { return } // "on", "id"… but keep "UI", "QA"
            count[key, default: 0] += 1
            weight[key] = max(weight[key] ?? 0, w)
            if display[key] == nil { display[key] = term }
        }

        /// A compound identifier: the joined form and its words ("SignupModal", "Signup Modal").
        /// Plain lowercase words ("cancel", "stop") are what dictation already gets right, so
        /// they're skipped; type-like names also get their words as a phrase.
        mutating func addIdentifier(_ name: String, weight w: Double, joined: Bool = true) {
            let words = ProjectVocabulary.words(of: name)
            if words.count < 2 && name == name.lowercased() { return }
            if joined { add(name, weight: words.count >= 2 ? w : w * 0.5) }
            guard words.count >= 2 else { return }
            if name.first?.isUppercase == true {
                add(words.joined(separator: " "), weight: w * 0.8)
            } else if name.contains("_") {
                add(words.map { $0.lowercased() }.joined(separator: " "), weight: w * 0.8)
            }
        }

        func ranked(limit: Int) -> [String] {
            count.keys
                .map { key in (key, (weight[key] ?? 1) * (1 + Foundation.log(Double(count[key] ?? 1)))) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .prefix(limit)
                .compactMap { display[$0.0] }
        }
    }

    private static let camelCase = regex(#"\b[A-Za-z][a-z0-9]*(?:[A-Z][A-Za-z0-9]*)+\b"#)
    private static let snakeCase = regex(#"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b"#)
    private static let declaration = regex(#"\b(?:class|struct|enum|protocol|interface|func|fun|def|function|type|object|component|data class|const)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private static let quoted = regex(#"(?<![\\\w])(["'`])([^\\\n{}<>]{2,40}?)\1"#)
    private static let uiContext = regex(#"\b(?:Text|Button|Label|Toggle|NavigationLink|Section|Tab|Menu|Alert|TextField|Picker)\s*\(|\b(?:title|placeholder|label|alt|aria-label|message|heading|subtitle|caption|tooltip|hint|header)\s*[:=]"#)
    private static let jsxText = regex(#">\s*([A-Z][^<>{}\n]{1,39}?)\s*<"#)
    private static let androidString = regex(#"<string\s+name="[^"]+"[^>]*>([^<]{2,40})</string>"#)
    private static let appleString = regex(#"=\s*"([^"\\\n]{2,40})"\s*;"#)
    private static let route = regex(#"["'`](/[a-z][a-z0-9-]*(?:/[a-z0-9:\[\]-]+)*)/?["'`]"#)
    private static let uiText = regex(#"^[A-Z][A-Za-z0-9'’&,!?.\- ]*$"#)

    private static func scan(_ text: String, of url: URL, into terms: inout Terms) {
        let name = url.lastPathComponent
        if name == "package.json" {
            packageJSON(text, into: &terms)
            return
        }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)

        for m in camelCase.matches(in: text, range: all) {
            terms.addIdentifier(ns.substring(with: m.range), weight: 1)
        }
        for m in snakeCase.matches(in: text, range: all) {
            terms.addIdentifier(ns.substring(with: m.range), weight: 1, joined: false)
        }
        for m in declaration.matches(in: text, range: all) {
            terms.addIdentifier(ns.substring(with: m.range(at: 1)), weight: 4)
        }
        // UI strings: short Title Case or sentence-case phrases, extra likely near Text("…"), title:, placeholder…
        for m in quoted.matches(in: text, range: all) {
            let literal = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard looksLikeUIText(literal) else { continue }
            let line = ns.lineRange(for: m.range)
            let nearUI = uiContext.firstMatch(in: text, range: line) != nil
            terms.add(literal, weight: nearUI ? 4 : 2)
        }
        for m in route.matches(in: text, range: all) {
            for segment in ns.substring(with: m.range(at: 1)).split(separator: "/") {
                guard segment.first?.isLetter == true else { continue } // skip :id, [slug]
                let phrase = segment.split(separator: "-").joined(separator: " ")
                terms.add(phrase, weight: 2)
            }
        }
        switch url.pathExtension.lowercased() {
        case "tsx", "jsx", "vue", "svelte", "html":
            for m in jsxText.matches(in: text, range: all) {
                let literal = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if looksLikeUIText(literal) { terms.add(literal, weight: 4) }
            }
        case "xml":
            for m in androidString.matches(in: text, range: all) {
                let literal = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if looksLikeUIText(literal) { terms.add(literal, weight: 4) }
            }
        case "strings":
            for m in appleString.matches(in: text, range: all) {
                let literal = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if looksLikeUIText(literal) { terms.add(literal, weight: 4) }
            }
        default: break
        }
    }

    /// "Sign up", "Forgot password?", "Save changes." — not paths, keys, or code.
    private static func looksLikeUIText(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= maxLength, uiText.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil,
              !s.contains("  ") else { return false }
        let words = s.split(separator: " ")
        guard words.count <= 6 else { return false }
        // A lone identifier ("SignupModal") is handled as an identifier; a lone word is fine if it's a real word.
        if words.count == 1 { return !s.dropFirst().contains(where: \.isUppercase) || s == s.uppercased() }
        return true
    }

    private static func packageJSON(_ text: String, into terms: inout Terms) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let name = json["name"] as? String {
            let bare = name.split(separator: "/").last.map(String.init) ?? name
            terms.add(bare, weight: 3)
            terms.add(bare.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " "), weight: 3)
        }
        for script in (json["scripts"] as? [String: Any])?.keys ?? [:].keys {
            terms.add(script, weight: 2)
            terms.add(script.split(whereSeparator: { $0 == "-" || $0 == ":" || $0 == "_" }).joined(separator: " "), weight: 2)
        }
    }

    private static func branches(in root: URL, into terms: inout Terms) {
        let result = Projects.git(["for-each-ref", "--format=%(refname:short)", "--count=30", "refs/heads/"], in: root, timeout: 3)
        guard result.status == 0 else { return }
        for line in result.output.split(separator: "\n") {
            let branch = line.trimmingCharacters(in: .whitespaces)
            guard !["main", "master", "develop", "HEAD"].contains(branch) else { continue }
            terms.add(branch, weight: 1)
            let words = branch.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" }).map(String.init)
                .flatMap { ProjectVocabulary.words(of: $0) }
            if words.count >= 2 { terms.add(words.joined(separator: " "), weight: 2) }
        }
    }

    /// "HTMLParserView" → ["HTML", "Parser", "View"]; "user_name" → ["user", "name"].
    static func words(of identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(identifier)
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "-" || c == " " {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if c.isUppercase, !current.isEmpty {
                let prev = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && next?.isLowercase == true) {
                    words.append(current); current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
