import Foundation

/// Talks to Android phones with adb (wireless debugging or USB), and finds
/// scrcpy for recording their screen and mic.
enum ADB {
    struct Device: Identifiable, Equatable {
        /// What adb calls it: `192.168.1.20:41235`, `adb-XXXX._adb-tls-connect._tcp`, or a USB serial.
        let serial: String
        let model: String
        /// device, unauthorized, offline…
        let state: String
        var id: String { serial }
        var isReady: Bool { state == "device" }
        var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls") }
        var isEmulator: Bool { serial.hasPrefix("emulator-") }
        /// How it's connected, for the Mobile page.
        var connection: String { isEmulator ? "Emulator" : isWireless ? "Wireless debugging" : "USB" }
    }

    static let helperPackage = "dev.critique.mobile"

    nonisolated(unsafe) private static var cachedAdb: String??
    nonisolated(unsafe) private static var cachedScrcpy: String??

    /// adb from the Android SDK, ANDROID_HOME, or Homebrew.
    static var adbPath: String? {
        if let cached = cachedAdb { return cached }
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], sdkRoot.path].compactMap { $0 }
            .map { "\($0)/platform-tools/adb" } + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cachedAdb = .some(found)
        return found
    }

    static var scrcpyPath: String? {
        if let cached = cachedScrcpy, cached != nil { return cached }
        let found = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"].first { FileManager.default.isExecutableFile(atPath: $0) }
        cachedScrcpy = .some(found)
        return found
    }

    static func forgetScrcpy() { cachedScrcpy = nil }

    static var sdkRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk")
    }

    /// A Java 17+ for Gradle builds, since apps opened from Finder don't get your shell's JAVA_HOME.
    static var javaHome: String? {
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"], !home.isEmpty { return home }
        return ["/opt/homebrew/opt/openjdk@17", "/opt/homebrew/opt/openjdk@21", "/opt/homebrew/opt/openjdk",
                "/Applications/Android Studio.app/Contents/jbr/Contents/Home"]
            .first { FileManager.default.isExecutableFile(atPath: "\($0)/bin/java") }
    }

    /// PATH and Android/Java settings for anything Critique runs for your phone.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = ["/opt/homebrew/bin", "/usr/local/bin", "\(sdkRoot.path)/platform-tools"]
        if let java = javaHome { env["JAVA_HOME"] = java; path.insert("\(java)/bin", at: 0) }
        if let adb = adbPath { env["ADB"] = adb; path.insert((adb as NSString).deletingLastPathComponent, at: 0) }
        env["PATH"] = (path + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        if env["ANDROID_HOME"] == nil, FileManager.default.fileExists(atPath: sdkRoot.path) { env["ANDROID_HOME"] = sdkRoot.path }
        return env
    }

    // MARK: Running commands

    struct Result {
        let status: Int32
        let output: String
        let error: String
        var ok: Bool { status == 0 }
        /// What to show when it failed.
        var message: String {
            let text = (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "exit \(status)" : text
        }
    }

    /// Runs a program to the end, off the main thread.
    static func run(_ executable: String, _ args: [String], in dir: URL? = nil, timeout: TimeInterval = 20) async -> Result {
        await Task.detached(priority: .userInitiated) { runBlocking(executable, args, in: dir, timeout: timeout) }.value
    }

    private static func runBlocking(_ executable: String, _ args: [String], in dir: URL?, timeout: TimeInterval) -> Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = environment
            if let dir { process.currentDirectoryURL = dir }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            // Read both pipes while it runs, so a chatty command can't fill one and stall.
            let group = DispatchGroup()
            let box = DataBox()
            for (pipe, isOut) in [(out, true), (err, false)] {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    box.set(data, isOut: isOut)
                    group.leave()
                }
            }
            do { try process.run() } catch {
                try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                return Result(status: -1, output: "", error: error.localizedDescription)
            }
            if group.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                group.wait()
                return Result(status: -1, output: box.out, error: "timed out")
            }
            process.waitUntilExit()
            return Result(status: process.terminationStatus, output: box.out, error: box.err)
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data(), errData = Data()
        func set(_ data: Data, isOut: Bool) { lock.withLock { if isOut { outData = data } else { errData = data } } }
        var out: String { lock.withLock { String(decoding: outData, as: UTF8.self) } }
        var err: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }
    }

    static func adb(_ args: [String], timeout: TimeInterval = 20) async -> Result {
        guard let adb = adbPath else { return Result(status: -1, output: "", error: "adb not found") }
        return await run(adb, args, timeout: timeout)
    }

    static func shell(_ serial: String, _ command: String, timeout: TimeInterval = 10) async -> Result {
        await adb(["-s", serial, "shell", command], timeout: timeout)
    }

    // MARK: Devices

    static func devices() async -> [Device] {
        let result = await adb(["devices", "-l"], timeout: 8)
        return result.output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return Device(serial: parts[0], model: model ?? parts[0], state: parts[1])
        }
    }

    /// Pairs with a phone's Wireless debugging ("Pair device with pairing code").
    /// adb only says "protocol fault" when it can't reach the phone, so the
    /// failure carries the reason from the adb server's log instead.
    static func pair(_ address: String, code: String) async -> Result {
        var result = await adb(["pair", address.filter { !$0.isWhitespace }, code], timeout: 20)
        // A server that macOS keeps off the local network: restart it as ours, and try again.
        if !result.output.contains("Successfully"), serverReason()?.contains("No route to host") == true {
            await restartServer()
            result = await adb(["pair", address.filter { !$0.isWhitespace }, code], timeout: 20)
        }
        if result.output.contains("Successfully") { return result }
        return Result(status: result.ok ? 1 : result.status, output: "", error: explain(result.message))
    }

    // MARK: The adb server

    /// macOS decides whether a program may reach the local network by the app
    /// that started it. The adb server keeps running after whatever started it
    /// (Android Studio, a terminal, an old Critique), and if that app isn't allowed
    /// on the local network, it can't find or reach your phone: "No route to host",
    /// and the phone waits forever after scanning the QR code. So before pairing,
    /// Critique restarts the server once, as its own.
    nonisolated(unsafe) private static var ownsServer = false

    static func takeOverServer() async {
        guard !ownsServer else { return }
        await restartServer()
    }

    static func restartServer() async {
        ownsServer = true
        log("mobile: restarting the adb server so it runs as Critique's")
        _ = await adb(["kill-server"], timeout: 10)
        _ = await adb(["start-server"], timeout: 15)
    }

    /// The adb server's log, where it says why pairing or connecting failed.
    private static var serverLog: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adb.\(getuid()).log")
    }

    /// Why the adb server last failed to reach a phone, from the end of its log,
    /// e.g. "failed to connect to '192.168.1.20:37099': No route to host".
    static func serverReason() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: serverLog) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let line = tail.split(separator: "\n").last(where: { $0.contains("failed to connect to") }),
              let range = line.range(of: "failed to connect to") else { return nil }
        // Only if it's recent: these lines start with "10-31 01:58:14.315".
        let stamp = line.prefix(14)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let year = Calendar.current.component(.year, from: Date())
        if let at = formatter.date(from: "\(year)-\(stamp)"), Date().timeIntervalSince(at) > 30 { return nil }
        return String(line[range.lowerBound...])
    }

    /// A failure in words you can act on.
    static func explain(_ message: String) -> String {
        let reason = message.contains("protocol fault") || message.contains("Unable to start pairing")
            ? serverReason() ?? message : message
        if reason.contains("No route to host") {
            return "macOS is keeping Critique off your local network. Turn on Critique in System Settings → Privacy & Security → Local Network, then try again."
        }
        if reason.contains("Connection refused") {
            return "Your phone isn't taking connections at that address. Check the IP address & port, and keep the pairing screen open on your phone (it gets a new port each time)."
        }
        if reason.contains("timed out") || reason.contains("Operation timed out") || reason.contains("Host is down") {
            return "Your phone didn't answer. Make sure it's on the same Wi‑Fi as this Mac."
        }
        if reason.contains("Wrong password") {
            return "The pairing code didn't match. Check the 6-digit code on your phone."
        }
        return reason
    }

    /// A Wireless debugging service the phone advertises over Bonjour, as `adb mdns services` lists it.
    struct Service {
        let name: String
        /// `_adb-tls-pairing._tcp` (waiting to pair) or `_adb-tls-connect._tcp` (ready to connect).
        let type: String
        let address: String
        var host: String { address.split(separator: ":").dropLast().joined(separator: ":") }
    }

    static func mdnsServices() async -> [Service] {
        let result = await adb(["mdns", "services"], timeout: 5)
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3, parts[1].hasPrefix("_adb-tls") else { return nil }
            return Service(name: parts[0], type: parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")), address: parts[2])
        }
    }

    /// Connects to a paired phone's Wireless debugging address.
    static func connect(_ address: String) async -> Result {
        let address = address.filter { !$0.isWhitespace }
        func attempt() async -> Result {
            let result = await adb(["connect", address], timeout: 15)
            // adb connect exits 0 even when it fails; it says so instead.
            let text = result.output + result.error
            if !result.ok || text.contains("failed") || text.contains("cannot") || text.contains("refused") {
                return Result(status: 1, output: "", error: text)
            }
            return result
        }
        var result = await attempt()
        if !result.ok, result.error.contains("No route to host") {
            await restartServer()
            result = await attempt()
        }
        return result.ok ? result : Result(status: 1, output: "", error: explain(result.error))
    }

    /// adb usually connects to a newly paired phone by itself. If it hasn't
    /// within a few seconds, connect to the phone's announced address.
    @discardableResult
    static func connectAfterPairing(host: String) async -> Bool {
        func connected() async -> Bool { await devices().contains { $0.isReady && $0.isWireless } }
        for _ in 0..<8 {
            if await connected() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        for _ in 0..<3 {
            if let service = await mdnsServices().first(where: { $0.type == "_adb-tls-connect._tcp" && $0.address.hasPrefix(host + ":") }) {
                _ = await connect(service.address)
            }
            if await connected() { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return await connected()
    }

    static func helperInstalled(_ serial: String) async -> Bool {
        await shell(serial, "pm path \(helperPackage)").output.contains("package:")
    }

    /// The helper APK that ships inside Critique.app (or next to the source when run from a build).
    static var helperAPK: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("critique-helper.apk")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // `swift run` from the repo
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/critique-helper.apk")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// Installs the tile and puts it in Quick Settings, so there's nothing to set up on the phone.
    static func installHelper(_ serial: String) async -> Result {
        guard let apk = helperAPK else { return Result(status: -1, output: "", error: "critique-helper.apk is missing from Critique.app") }
        let result = await adb(["-s", serial, "install", "-r", apk.path], timeout: 60)
        if result.ok { _ = await shell(serial, "cmd statusbar add-tile \(helperPackage)/.CritiqueTile") }
        return result
    }

    /// Tells the tile what Critique is doing: idle, recording, or sending.
    static func setTile(_ serial: String, _ state: String) {
        Task { _ = await shell(serial, "am broadcast -n \(helperPackage)/.StateReceiver --es state \(state)") }
    }

    /// The app on screen: package and activity, e.g. ("bordgame.app", "com.bord.app.MainActivity").
    static func foreground(_ serial: String) async -> (package: String, activity: String)? {
        let out = await shell(serial, "dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity'", timeout: 4).output
        // … u0 bordgame.app/com.bord.app.MainActivity t123}
        guard let token = out.split(whereSeparator: { $0 == " " || $0 == "}" }).first(where: { $0.contains("/") }) else { return nil }
        let parts = token.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let activity = parts[1].hasPrefix(".") ? parts[0] + parts[1] : parts[1]
        return (parts[0], activity)
    }

    /// Screen size in pixels, as the phone reports it in its natural (portrait) orientation.
    static func screenSize(_ serial: String) async -> CGSize? {
        let out = await shell(serial, "wm size").output
        // "Physical size: 1080x2400" and maybe "Override size: …" (the one in use)
        let line = out.split(separator: "\n").last { $0.contains("size:") }
        guard let dims = line?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x"),
              dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) else { return nil }
        return CGSize(width: w, height: h)
    }
}
