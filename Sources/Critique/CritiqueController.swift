import AppKit
import AVFoundation
import Carbon.HIToolbox
import Speech

/// Runs a feedback session. Double-tap right Option to start, then just talk and
/// point with your cursor; hold ` to draw on the screen. Double-tap again to send.
/// (⌃⌥Space also works; esc cancels.)
///
/// One session records, on a shared clock:
///  - your voice (transcribed with a time for every word)
///  - a video of your screen with your voice
///  - a screenshot each time you point, draw, or click — with your mark drawn in
///  - every button/link/menu item you hover or click, even ones too fleeting to screenshot
@MainActor
final class CritiqueController {
    let session = Session()
    private lazy var bar = PillPanel(session: session) { [weak self] in self?.send() }
    private let dictation = Dictation()
    private let pointer = PointerTracker()
    private let recorder = ScreenRecorder()
    let handoff = AgentHandoff()
    private var trigger: RightOptionTap?
    private var sessionKeys: [UInt32] = []
    private var hideWork: DispatchWorkItem?
    private var sending = false
    private var lastLevelAt = Date.distantPast
    private let maxShots = 30

    init() {
        dictation.onSpeech = { [weak self] text, words in
            guard let self else { return }
            self.session.updateSpeech(text, words: words)
        }
        dictation.onSegmentEnd = { [weak self] in self?.session.commitSpeech() }
        dictation.onLevel = { [weak self] level in self?.heard(level) }
        pointer.ignore = { [weak self] p in self?.bar.frame.contains(p) ?? false }
        pointer.onGesture = { [weak self] gesture, p, since in self?.capture(gesture, at: p, since: since) }
        pointer.onHover = { [weak self] p in self?.hovered(p) }

        trigger = RightOptionTap { [weak self] in self?.toggle() }
        // Backup trigger that works even without Input Monitoring permission.
        HotKeys.shared.register(kVK_Space, controlKey | optionKey) { [weak self] in self?.toggle() }
    }

    func toggle() {
        guard !sending else { return }
        session.isActive ? send() : start()
    }

    // MARK: Session lifecycle

    func start() {
        hideWork?.cancel()
        session.reset()
        session.mode = .listening
        let screen = ScreenCapture.screenUnderMouse()
        bar.show(on: screen)
        play("Pop")
        sessionKeys = [
            HotKeys.shared.register(kVK_Escape, 0) { [weak self] in self?.cancel() },
            // Hold ` to draw with the cursor.
            HotKeys.shared.register(kVK_ANSI_Grave, 0, onRelease: { [weak self] in
                self?.session.isDrawing = false
                self?.pointer.endDrawing()
            }) { [weak self] in
                self?.session.isDrawing = true
                self?.pointer.beginDrawing()
            },
        ].compactMap { $0 }
        pointer.start()
        if let app = NSWorkspace.shared.frontmostApplication { ElementLocator.wakeUp(app.processIdentifier) }

        // Check screen access up front (macOS's permission check can be stale,
        // so try a capture) — screenshots themselves are only taken when you draw.
        Task {
            do {
                _ = try await ScreenCapture.capture(screen)
            } catch {
                guard session.isActive else { return }
                cancel()
                ScreenCapture.requestPermission()
                notice("Critique can't see your screen. Turn it on in System Settings → Privacy & Security → Screen Recording, then reopen Critique.", seconds: 7)
            }
        }
        Task {
            do {
                try await recorder.start(screen, excluding: [bar.windowNumber])
            } catch {
                log("screen recording unavailable: \(error.localizedDescription)")
            }
            if !session.isActive { await recorder.discard() }
        }
        Task {
            log("session started — speech permission \(SFSpeechRecognizer.authorizationStatus().rawValue), microphone \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = allowed, 0 = not asked yet)")
            let allowed = await Dictation.authorize()
            guard session.mode == .listening else { return }
            do {
                guard allowed else { throw NSError(domain: "Critique", code: 4) }
                try dictation.start()
            } catch {
                log("can't listen: \(error.localizedDescription)")
                session.micAvailable = false
                session.mode = .typing
                bar.makeKey()
            }
        }
    }

    func send() {
        guard session.isActive, !sending else { return }
        sending = true
        pointer.stop()
        endKeys()
        bar.releaseFocus()
        session.mode = .sent("Wrapping up…")
        // Let speech recognition finish your last words, then close the video.
        dictation.finish { [weak self] in
            guard let self else { return }
            Task {
                let video = await self.recorder.stop()
                await self.improveTranscript(from: video)
                self.save(video: video)
            }
        }
    }

    /// Live speech recognition can drop words; re-transcribe the recording and
    /// use that if it caught more.
    private func improveTranscript(from video: URL?) async {
        guard let video, session.micAvailable, let start = recorder.startedAt else { return }
        let words = await Dictation.transcribe(video)
        let live = session.spoken.count
        log("recording transcript: \(words.count) words (live: \(live))")
        guard words.count > live else { return }
        session.replaceTranscript(with: words.map { SpokenWord(text: $0.text, time: start.addingTimeInterval($0.at)) })
    }

    private func save(video: URL?) {
        session.finalizeText()
        let notes = session.committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let pointedAtSomething = !session.shots.isEmpty
        guard !notes.isEmpty || pointedAtSomething else {
            if let video { try? FileManager.default.removeItem(at: video) }
            sending = false
            notice("Nothing to send — talk while you point at things.", seconds: 2.5)
            return
        }
        let input = FeedbackWriter.Input(notes: notes, shots: session.shots, words: session.spoken,
                                         interactions: session.interactions,
                                         video: video, clockStart: recorder.startedAt ?? session.startedAt,
                                         duration: Date().timeIntervalSince(recorder.startedAt ?? session.startedAt))
        Task.detached(priority: .userInitiated) {
            let result = Result { try FeedbackWriter.write(input) }
            await MainActor.run { self.finishSending(result) }
        }
    }

    private func finishSending(_ result: Result<(dir: URL, record: FeedbackRecord), Error>) {
        sending = false
        switch result {
        case .success(let (dir, record)):
            NotificationCenter.default.post(name: CritiqueStore.didSave, object: nil)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(record.markdown(in: dir), forType: .string)
            play("Glass")
            let count = record.shots.count
            var summary = "\(count) screenshot\(count == 1 ? "" : "s")"
            if record.video != nil, let duration = record.duration { summary += ", \(FeedbackRecord.clock(duration)) recording" }
            sending = true // hold off new sessions until the paste is done
            let path = dir.appendingPathComponent("feedback.md").path
            let line = "Implement my UX feedback from Critique: \(path) (\(summary)). Read it and look at the screenshots first."
            handoff.deliver(line: line) { [weak self] app in
                guard let self else { return }
                self.sending = false
                if let app {
                    self.notice(nil, sent: "In \(app) — press ⏎ to implement", seconds: 2.4)
                } else {
                    self.notice(nil, sent: "\(summary) · copied — paste it into Claude Code (⌘V)", seconds: 3.5)
                }
            }
        case .failure(let error):
            notice("Couldn't save feedback: \(error.localizedDescription)", seconds: 4)
        }
    }

    func cancel() {
        guard session.isActive else { return }
        dictation.stop()
        pointer.stop()
        endKeys()
        bar.releaseFocus()
        session.mode = .idle
        bar.hide()
        Task { await recorder.discard() }
    }

    // MARK: Pointing

    /// The cursor settled somewhere: note the button/link/menu item under it.
    private func hovered(_ p: NSPoint) {
        guard session.isActive else { return }
        let at = Date()
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? ScreenCapture.screenUnderMouse()
        let maxArea = screen.frame.width * screen.frame.height * 0.15
        Task {
            guard let element = await ElementLocator.element(at: Self.topLeft(p), maxArea: maxArea),
                  element.isInteractive, session.isActive else { return }
            session.log(.hover, element.label, at: at)
        }
    }

    /// A click is logged for the timeline. A drawing gets a whole-screen screenshot
    /// with your stroke on it — the only time Critique takes screenshots.
    private func capture(_ gesture: PointerTracker.Gesture, at p: NSPoint, since: Date) {
        guard session.isActive else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? ScreenCapture.screenUnderMouse()
        let maxArea = screen.frame.width * screen.frame.height * 0.15

        switch gesture {
        case .click:
            Task {
                if let element = await ElementLocator.element(at: Self.topLeft(p), maxArea: maxArea), session.isActive {
                    session.log(.click, element.label, at: since)
                }
            }
        case .drawing(let stroke):
            let drawn = Self.bounds(of: stroke)
            guard drawn.width > 10 || drawn.height > 10 else { return } // a tap, not a drawing
            let context = ScreenCapture.windowContext(at: Self.topLeft(NSPoint(x: drawn.midX, y: drawn.midY)))
            Task {
                guard session.shots.count < maxShots else { return }
                let inside = await ElementLocator.elements(in: Self.topLeft(drawn.insetBy(dx: -12, dy: -12)), maxArea: maxArea).map(\.label)
                guard let image = try? await ScreenCapture.capture(screen), session.isActive else { return }
                let scale = CGFloat(image.width) / screen.frame.width
                func px(_ q: NSPoint) -> CGPoint {
                    CGPoint(x: (q.x - screen.frame.minX) * scale, y: (screen.frame.maxY - q.y) * scale)
                }
                let box = drawn.insetBy(dx: -12, dy: -12).intersection(screen.frame)
                let region = CGRect(x: (box.minX - screen.frame.minX) * scale, y: (screen.frame.maxY - box.maxY) * scale,
                                    width: box.width * scale, height: box.height * scale)
                session.addShot({
                    Shot(number: $0, kind: .drawing, image: image, region: region,
                         app: context.app, window: context.title, stroke: stroke.map(px), inside: inside)
                }, at: since)
            }
        }
    }

    private static func bounds(of points: [NSPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Global Cocoa (bottom-left origin) ↔ global top-left coordinates.
    private static func topLeft(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: NSScreen.screens[0].frame.height - p.y)
    }

    private static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: NSScreen.screens[0].frame.height - r.maxY, width: r.width, height: r.height)
    }

    private static func cocoa(_ r: CGRect) -> CGRect { topLeft(r) } // the flip is its own inverse

    // MARK: Helpers

    private func heard(_ level: Float) {
        session.level = level
        if Date().timeIntervalSince(lastLevelAt) > 0.05 {
            lastLevelAt = Date()
            session.pushLevel(level)
        }
    }

    private func endKeys() {
        for id in sessionKeys { HotKeys.shared.unregister(id) }
        sessionKeys = []
        session.isDrawing = false
    }

    func notice(_ text: String?, sent: String? = nil, seconds: Double) {
        hideWork?.cancel()
        session.mode = sent.map { .sent($0) } ?? .notice(text ?? "")
        bar.show(on: ScreenCapture.screenUnderMouse())
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.session.isActive, !self.sending else { return }
            self.session.mode = .idle
            self.bar.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}

