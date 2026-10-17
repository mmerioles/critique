import AppKit
import ScreenCaptureKit

/// Records the screen plus your microphone into a .mov for the whole session,
/// so the agent can see motion (animations, hovers, flows) — not just stills.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?
    private(set) var url: URL?
    private(set) var startedAt: Date?

    /// `excluding` are window numbers to leave out of the video (Critique's bar).
    func start(_ screen: NSScreen, excluding windowNumbers: [Int], microphone: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
        let hidden = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)

        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * min(screen.backingScaleFactor, 1.5))
        config.height = Int(screen.frame.height * min(screen.backingScaleFactor, 1.5))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.captureMicrophone = microphone

        let dir = Inbox.root.deletingLastPathComponent().appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).mov")
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .hevc

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        self.url = url
        self.startedAt = Date()
    }

    /// Stops and returns the finished video file, if there is one.
    func stop() async -> URL? {
        guard let stream else { return nil }
        self.stream = nil
        await withCheckedContinuation { cont in
            finished = cont
            Task {
                try? await stream.stopCapture()
                try? await Task.sleep(for: .seconds(3)) // safety net if the finish callback never comes
                self.resumeFinished()
            }
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func discard() async {
        if let url = await stop() { try? FileManager.default.removeItem(at: url) }
        url = nil
        startedAt = nil
    }

    private func resumeFinished() {
        DispatchQueue.main.async {
            self.finished?.resume()
            self.finished = nil
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { resumeFinished() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { resumeFinished() }
    func stream(_ stream: SCStream, didStopWithError error: Error) { resumeFinished() }
}
