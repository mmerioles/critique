import AVFoundation
import CoreGraphics
import Foundation

/// Critiques from an Android phone. Tap the Critique tile in Quick Settings to
/// start, use the app and talk, and tap it again to send. Critique records the
/// phone's screen and mic over adb (scrcpy), logs your taps and swipes, and hands
/// the critique to the agent like any other. Then, if you want, it rebuilds the
/// app and reinstalls it on the phone once the agent is done.
@MainActor
final class Mobile: ObservableObject {
    static let shared = Mobile()

    enum Phase: Equatable {
        case idle, recording(since: Date), sending
    }

    @Published private(set) var devices: [ADB.Device] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var helperInstalled: [String: Bool] = [:]
    @Published private(set) var installer = InstallStatus.idle
    /// The phone critiques come from. The first connected one unless you pick another.
    @Published var selected: String? = UserDefaults.standard.string(forKey: "mobile.device") {
        didSet { UserDefaults.standard.set(selected, forKey: "mobile.device"); listen() }
    }
    /// Rebuild and reinstall the app on the phone once the agent has made its changes.
    @Published var autoInstall: Bool = UserDefaults.standard.object(forKey: "mobile.autoInstall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "mobile.autoInstall") }
    }

    /// Hands a saved critique to the agent (CritiqueController does this for desktop critiques too).
    var deliver: ((Result<(dir: URL, record: FeedbackRecord), Error>) -> Void)?
    /// Shows a short message in Critique's pill on the Mac.
    var notice: ((String) -> Void)?

    var device: ADB.Device? {
        // Wireless debugging addresses change when you toggle it, so fall back to any connected phone.
        devices.first { $0.serial == selected && $0.isReady } ?? devices.first(where: \.isReady)
    }

    private var listener: LineProcess?
    private var listeningTo: String?
    private var pollTask: Task<Void, Never>?
    private var recording: Recording?

    // MARK: Watching for phones

    /// Keeps the device list fresh and listens for the tile on the chosen phone.
    func startWatching() {
        guard pollTask == nil, ADB.adbPath != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        let found = await ADB.devices()
        if found != devices { devices = found }
        for device in found where device.isReady && helperInstalled[device.serial] == nil {
            helperInstalled[device.serial] = await ADB.helperInstalled(device.serial)
        }
        listen()
    }

    func installHelper() async -> ADB.Result? {
        guard let device else { return nil }
        let result = await ADB.installHelper(device.serial)
        helperInstalled[device.serial] = await ADB.helperInstalled(device.serial)
        if result.ok { ADB.setTile(device.serial, "idle") }
        return result
    }

    /// Watches the phone's log for the tile's "toggle". The tile only logs; this
    /// is the one place that decides to start or send.
    private func listen() {
        let serial = device?.serial
        guard serial != listeningTo || listener?.isRunning != true else { return }
        listener?.onExit = nil
        listener?.stop()
        listener = nil
        listeningTo = serial
        guard let serial, let adb = ADB.adbPath else { return }
        Task {
            // Only taps from now on, not old ones still in the log.
            let now = await ADB.shell(serial, "date +%s").output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard listeningTo == serial, Int(now) != nil else { return }
            let process = LineProcess(adb, ["-s", serial, "logcat", "-T", "\(now).000", "-s", "CritiqueTile:I"]) { [weak self] line in
                if line.contains("toggle") { self?.toggle() }
            }
            process.onExit = { [weak self] _ in
                // Phone went away or adb restarted; the next refresh reconnects.
                if self?.listeningTo == serial { self?.listeningTo = nil; self?.listener = nil }
            }
            do { try process.start(); listener = process } catch { log("mobile: can't watch logcat: \(error)") }
        }
    }

    // MARK: A critique

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: send()
        case .sending: break
        }
    }

    func start() {
        guard phase == .idle, let device else { return }
        guard let scrcpy = ADB.scrcpyPath else {
            notice?("Install scrcpy to record your phone: brew install scrcpy")
            ADB.setTile(device.serial, "idle")
            return
        }
        Agents.shared.ensureRunning()
        let recording = Recording(device: device)
        do {
            try recording.start(scrcpy: scrcpy)
        } catch {
            notice?("Couldn't record \(device.model): \(error.localizedDescription)")
            ADB.setTile(device.serial, "idle")
            return
        }
        self.recording = recording
        phase = .recording(since: Date())
        ADB.setTile(device.serial, "recording")
        Task { _ = await ADB.shell(device.serial, "cmd statusbar collapse") }
        notice?("Recording \(device.model) — tap the Critique tile again to send")
    }

    func send() {
        guard case .recording = phase, let recording else { return }
        phase = .sending
        ADB.setTile(recording.device.serial, "sending")
        Task {
            _ = await ADB.shell(recording.device.serial, "cmd statusbar collapse")
            let result = await recording.finish()
            self.recording = nil
            phase = .idle
            ADB.setTile(recording.device.serial, "idle")
            switch result {
            case .success(let saved):
                let sent = Date()
                deliver?(.success(saved))
                if autoInstall, let project = saved.record.project {
                    installAfterAgent(project: project, serial: recording.device.serial, package: recording.package, since: sent)
                }
            case .failure(let error):
                notice?(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard let recording else { return }
        recording.discard()
        self.recording = nil
        phase = .idle
        ADB.setTile(recording.device.serial, "idle")
    }

    // MARK: Reinstalling after the fix

    enum InstallStatus: Equatable {
        case idle
        case waiting(String)
        case building(String)
        case done(String)
        case failed(String)

        var text: String? {
            switch self {
            case .idle: nil
            case .waiting(let s), .building(let s), .done(let s), .failed(let s): s
            }
        }
    }

    private var installTask: Task<Void, Never>?

    /// Waits for the agent to start and then finish on this critique (sent at
    /// `since`), then builds and installs the app if anything changed.
    private func installAfterAgent(project: FeedbackRecord.ProjectRecord, serial: String, package: String?, since: Date) {
        let dir = URL(fileURLWithPath: project.path)
        guard let gradle = Installer.gradleProject(in: dir) else {
            installer = .failed("No Gradle project in \(project.name), so nothing to reinstall")
            return
        }
        installTask?.cancel()
        let before = Installer.snapshot(dir)
        installer = .waiting("Waiting for the agent to finish…")
        installTask = Task {
            // The agent says when it's done with the turn the critique started (it
            // gives up if nothing starts in 3 minutes). With no agent of our own,
            // give whatever picked it up over MCP the same 3 minutes.
            if let agent = Agents.shared.agent(for: project) {
                _ = await agent.turnFinished(after: since)
            } else {
                try? await Task.sleep(for: .seconds(180))
            }
            guard !Task.isCancelled else { return }
            guard Installer.snapshot(dir) != before else {
                installer = .done("No changes to install")
                return
            }
            installer = .building("Building and installing on your phone…")
            ADB.setTile(serial, "installing")
            notice?("Building the fix and installing it on your phone…")
            let result = await Installer.install(gradle: gradle, serial: serial)
            guard !Task.isCancelled else { return }
            if result.ok {
                if let package { _ = await ADB.shell(serial, "monkey -p \(package) -c android.intent.category.LAUNCHER 1") }
                installer = .done("Installed the fix at \(Date().formatted(date: .omitted, time: .shortened))")
                ADB.setTile(serial, "installed")
                notice?("Fix installed on your phone")
            } else {
                let last = result.message.split(separator: "\n").suffix(3).joined(separator: " ")
                installer = .failed("Build failed: \(last)")
                ADB.setTile(serial, "idle")
                notice?("Couldn't install the fix — see Critique's Mobile page")
            }
        }
    }

    func installNow() {
        guard let project = Projects.activeRecord(), let device else { return }
        guard let gradle = Installer.gradleProject(in: URL(fileURLWithPath: project.path)) else {
            installer = .failed("No Gradle project in \(project.name)")
            return
        }
        installTask?.cancel()
        installer = .building("Building and installing on your phone…")
        installTask = Task {
            let result = await Installer.install(gradle: gradle, serial: device.serial)
            installer = result.ok ? .done("Installed at \(Date().formatted(date: .omitted, time: .shortened))")
                : .failed("Build failed: \(result.message.split(separator: "\n").suffix(3).joined(separator: " "))")
        }
    }
}

/// Builds and installs an Android app with its Gradle wrapper.
enum Installer {
    /// The folder with `gradlew`: the project itself or its `android/` folder.
    static func gradleProject(in dir: URL) -> URL? {
        [dir, dir.appendingPathComponent("android")].first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("gradlew").path)
        }
    }

    /// What the working tree looks like, to tell whether the agent changed anything.
    static func snapshot(_ dir: URL) -> String {
        let head = Projects.git(["rev-parse", "HEAD"], in: dir).output
        let diff = Projects.git(["diff", "HEAD"], in: dir, timeout: 20).output
        let untracked = Projects.git(["status", "--porcelain", "--untracked-files=all"], in: dir).output
        return head + "\n" + String(diff.hashValue) + "\n" + untracked
    }

    static func install(gradle: URL, serial: String) async -> ADB.Result {
        // ANDROID_SERIAL makes Gradle install on this phone even if an emulator is running too.
        await ADB.run("/bin/sh", ["-c", "ANDROID_SERIAL='\(serial)' ./gradlew installDebug --console=plain -q"],
                      in: gradle, timeout: 15 * 60)
    }
}

/// One phone critique in progress: scrcpy recording the screen and mic, getevent
/// logging touches, and a note of which app is on screen.
@MainActor
final class Recording {
    let device: ADB.Device
    private(set) var package: String?
    private let video = FileManager.default.temporaryDirectory.appendingPathComponent("critique-phone-\(UUID().uuidString).mp4")
    private var scrcpy: LineProcess?
    private var touches: LineProcess?
    private var touchLog: TouchLog?
    private var apps: [(at: Date, package: String, activity: String)] = []
    private var appTask: Task<Void, Never>?
    private var scrcpyOutput: [String] = []
    private let startedAt = Date()
    private var stoppedAt = Date()

    init(device: ADB.Device) { self.device = device }

    func start(scrcpy path: String) throws {
        let process = LineProcess(path, [
            "-s", device.serial, "--no-window", "--no-playback",
            "--record=\(video.path)", "--record-format=mp4",
            "--video-codec=h264", "--max-size=1920", "--video-bit-rate=6M",
            "--audio-source=mic", "--audio-codec=aac",
            "--show-touches",
        ]) { [weak self] line in
            self?.scrcpyOutput.append(line)
            log("scrcpy: \(line)")
        }
        try process.start()
        scrcpy = process
        startTouches()
        // Which app you're in, for the agent and for relaunching after a reinstall.
        let serial = device.serial
        appTask = Task { [weak self] in
            while !Task.isCancelled {
                if let app = await ADB.foreground(serial) {
                    guard let self else { return }
                    if self.apps.last?.activity != app.activity { self.apps.append((Date(), app.package, app.activity)) }
                    if app.package != "com.android.systemui" { self.package = app.package }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startTouches() {
        let serial = device.serial
        Task {
            async let listing = ADB.shell(serial, "getevent -lp", timeout: 5)
            async let size = ADB.screenSize(serial)
            guard let screen = TouchLog.touchscreen(in: await listing.output), let size = await size,
                  let adb = ADB.adbPath, scrcpy?.isRunning == true else {
                log("mobile: no touchscreen found; taps won't be logged")
                return
            }
            touchLog = TouchLog(screen: screen, size: size)
            // -tt gives getevent a terminal so it prints each event right away.
            let process = LineProcess(adb, ["-s", serial, "shell", "-tt", "getevent", "-lt", screen.path]) { [weak self] line in
                self?.touchLog?.feed(line)
            }
            try? process.start()
            touches = process
        }
    }

    func discard() {
        appTask?.cancel()
        touches?.stop()
        scrcpy?.stop()
        try? FileManager.default.removeItem(at: video)
    }

    /// Stops recording and writes the critique to the inbox.
    func finish() async -> Result<(dir: URL, record: FeedbackRecord), Error> {
        stoppedAt = Date()
        appTask?.cancel()
        touches?.stop()
        scrcpy?.interrupt()
        await scrcpy?.waitForExit(timeout: 10)

        guard FileManager.default.fileExists(atPath: video.path) else {
            let why = scrcpyOutput.last { $0.contains("ERROR") } ?? "scrcpy didn't save a recording"
            return .failure(NSError(domain: "Critique", code: 10, userInfo: [NSLocalizedDescriptionKey: "Couldn't record \(device.model): \(why)"]))
        }
        let asset = AVURLAsset(url: video)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        // The recording ends when scrcpy stops, so it began `duration` before that.
        let clockStart = duration > 0 ? stoppedAt.addingTimeInterval(-duration) : startedAt.addingTimeInterval(1)

        // Your voice, from the phone's mic.
        var audio: URL?
        var words: [SpokenWord] = []
        var engine: String?
        if let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty {
            let url = video.deletingPathExtension().appendingPathExtension("m4a")
            if await Transcriber.exportAudio(from: video, to: url) {
                audio = url
                let hints = [device.model] + apps.map(\.package)
                if let (heard, name) = await Transcriber.transcribe(url, hints: hints) {
                    words = heard.map { SpokenWord(text: $0.text, time: clockStart.addingTimeInterval($0.at)) }
                    engine = name
                }
            }
        }

        let (shots, interactions) = await gestures(clockStart: clockStart, asset: asset)
        let notes = Self.notes(words: words, shots: shots)
        guard !notes.isEmpty || !shots.isEmpty else {
            discard()
            if let audio { try? FileManager.default.removeItem(at: audio) }
            return .failure(NSError(domain: "Critique", code: 11, userInfo: [NSLocalizedDescriptionKey: "Nothing to send — talk while you tap around the app."]))
        }

        var input = FeedbackWriter.Input(notes: notes, shots: shots, words: words, interactions: interactions,
                                         video: video, clockStart: clockStart, duration: duration)
        input.audio = audio
        input.engine = engine
        input.device = FeedbackRecord.DeviceRecord(
            model: device.model, serial: device.serial,
            app: package, activity: apps.last { $0.package == package }?.activity,
            reinstalls: Mobile.shared.autoInstall)
        let toWrite = input
        return await Task.detached(priority: .userInitiated) { Result { try FeedbackWriter.write(toWrite) } }.value
    }

    /// Taps and long presses become screenshots (a frame from the recording with a
    /// ring where your finger was); swipes go in the timeline.
    private func gestures(clockStart: Date, asset: AVURLAsset) async -> ([Shot], [Interaction]) {
        guard let log = touchLog else { return ([], []) }
        let size = log.size
        let kept = log.gestures.filter { g in
            // Your last tap on the tile, and pulling down the shade to reach it.
            if g.ended > stoppedAt.addingTimeInterval(-1.5) { return false }
            if g.began < clockStart.addingTimeInterval(0.8) { return false }
            if case .swipe("down") = g.kind, g.start.y < size.height * 0.08 { return false }
            return true
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero

        var shots: [Shot] = []
        var interactions: [Interaction] = []
        for g in kept {
            let app = apps.last { $0.at <= g.began } ?? apps.first
            switch g.kind {
            case .swipe(let direction):
                interactions.append(Interaction(kind: .swipe, label: "swiped \(direction)\(app.map { " in \($0.package)" } ?? "")", time: g.began))
            case .tap, .longPress:
                guard shots.count < 20 else { continue }
                // Just before the finger landed, so the screen shows what they meant to tap.
                let t = max(0, g.began.timeIntervalSince(clockStart) - 0.05)
                guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
                let isLong: Bool = { if case .longPress = g.kind { return true }; return false }()
                var shot = Shot(number: shots.count + 1, kind: .tap, image: image,
                                app: app?.package, window: app.map { Self.short($0.activity) },
                                element: isLong ? "(long press)" : nil)
                // Recording and screen in the same orientation: mark the spot.
                let w = CGFloat(image.width), h = CGFloat(image.height)
                if (w > h) == (size.width > size.height) {
                    let p = CGPoint(x: g.start.x / size.width * w, y: g.start.y / size.height * h)
                    let r = max(w, h) * 0.025
                    shot.point = p
                    shot.region = CGRect(x: p.x - r * 1.6, y: p.y - r * 1.6, width: r * 3.2, height: r * 3.2)
                        .intersection(CGRect(x: 0, y: 0, width: w, height: h))
                    shot.stroke = (0...36).map { i in
                        let a = Double(i) / 36 * 2 * .pi + .pi * 0.75
                        return CGPoint(x: p.x + r * cos(a), y: p.y + r * sin(a))
                    }
                }
                shot.time = g.began
                shots.append(shot)
            }
        }
        return (shots, interactions)
    }

    /// Your words, with [#n] where each tap happened.
    private static func notes(words: [SpokenWord], shots: [Shot]) -> String {
        var pending = shots.sorted { $0.time < $1.time }
        var parts: [String] = []
        for word in words {
            while let next = pending.first, next.time <= word.time {
                parts.append("[#\(next.number)]")
                pending.removeFirst()
            }
            parts.append(word.text)
        }
        let spoken = !words.isEmpty
        parts += pending.map { "[#\($0.number)]" }
        return spoken ? parts.joined(separator: " ") : ""
    }

    /// com.bord.app.ui.MainActivity → MainActivity
    private static func short(_ activity: String) -> String {
        activity.split(separator: ".").last.map(String.init) ?? activity
    }
}
