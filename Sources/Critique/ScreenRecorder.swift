import AppKit
import ScreenCaptureKit

/// Records the screen plus your microphone into a .mov for the whole session,
/// so the agent can see motion (animations, hovers, flows) — not just stills.
///
/// Every call can overlap with every other (start while a stop is in flight, a
/// delegate callback mid-stop), so all state lives under one lock and a start
/// that finishes after the session already ended stops its own stream.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput {
    /// Where in-progress recordings go. Anything here that isn't being written right now is an orphan.
    static var scratch: URL { Inbox.root.deletingLastPathComponent().appendingPathComponent("recording") }
    /// The recorder stops itself this long after the session limit, in case the controller never does.
    static let grace: TimeInterval = 60

    /// Frames also go here and are ignored. Without a stream output, ScreenCaptureKit
    /// logs an error for every frame (over a hundred a second) while recording to file.
    private let frames = DispatchQueue(label: "critique.recorder.frames", qos: .utility)
    private let lock = NSLock()
    private var stream: SCStream?
    /// Bumped by every start and stop, so a start still waiting on startCapture
    /// can tell that the session it was for is already over.
    private var generation = 0
    private var waiter: Once?
    private var watchdog: Task<Void, Never>?
    private var fileURL: URL?
    private var started: Date?

    var url: URL? { lock.withLock { fileURL } }
    var startedAt: Date? { lock.withLock { started } }

    /// `excluding` are window numbers to leave out of the video (Critique's bar).
    /// `limit` is the longest a session may run; the recorder stops itself `grace` after it.
    func start(_ screen: NSScreen, excluding windowNumbers: [Int], microphone: Bool, limit: TimeInterval) async throws {
        // Never leave an earlier recording running in the background.
        await discard()
        let generation = lock.withLock { self.generation += 1; return self.generation }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
        let hidden = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)

        // 1x points and 15 fps: text stays readable, and a minute is a few times smaller
        // than at Retina scale and 30 fps. SCRecordingOutput has no bitrate setting.
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width)
        config.height = Int(screen.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.showsCursor = true
        config.captureMicrophone = microphone

        let dir = Self.scratch
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).mov")
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .hevc

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: frames) }
        try await stream.startCapture()

        let stale = lock.withLock { () -> Bool in
            guard self.generation == generation else { return true }
            self.stream = stream
            fileURL = url
            started = Date()
            return false
        }
        if stale {
            // The session ended (or a new one began) while capture was starting up.
            log("screen recording started after its session ended — stopping it")
            await finish(stream)
            try? FileManager.default.removeItem(at: url)
            return
        }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit + Self.grace))
            guard let self, !Task.isCancelled else { return }
            log("screen recording ran \(Int((limit + Self.grace) / 60)) min with no stop — stopping it")
            _ = await self.stop()
        }
        lock.withLock { self.watchdog = watchdog }
    }

    /// Stops and returns the finished video file, if there is one. Also returns it
    /// when the watchdog already stopped the stream, so the controller can still save it.
    func stop() async -> URL? {
        let stream = lock.withLock { () -> SCStream? in
            generation += 1
            watchdog?.cancel()
            watchdog = nil
            let s = self.stream
            self.stream = nil
            return s
        }
        if let stream { await finish(stream) }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func discard() async {
        if let url = await stop() { try? FileManager.default.removeItem(at: url) }
        lock.withLock {
            fileURL = nil
            started = nil
        }
    }

    /// Stops capture and waits for the file to be finished, 3 s at most.
    private func finish(_ stream: SCStream) async {
        let done = Once()
        lock.withLock { waiter = done }
        try? await stream.stopCapture()
        Task {
            try? await Task.sleep(for: .seconds(3)) // safety net if the finish callback never comes
            done.fire()
        }
        await done.wait()
        lock.withLock { if waiter === done { waiter = nil } }
    }

    private func fireWaiter() { lock.withLock { waiter }?.fire() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { fireWaiter() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        log("screen recording failed: \(error.localizedDescription)")
        fireWaiter()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("screen recording stopped: \(error.localizedDescription)")
        fireWaiter()
    }
}

/// One wait, resumed exactly once no matter how many callbacks (or the safety net) fire,
/// and in any order — fire before wait just makes the wait return at once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if fired { return true }
                continuation = cont
                return false
            }
            if already { cont.resume() }
        }
    }

    func fire() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            fired = true
            defer { continuation = nil }
            return continuation
        }
        cont?.resume()
    }
}
