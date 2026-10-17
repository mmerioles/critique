import AVFoundation
@preconcurrency import Speech

/// Live speech-to-text from the microphone, with a time for every word so
/// screenshots can be matched to what you were saying when you took them.
@MainActor
final class Dictation {
    /// Text of the current stretch of speech, with word times.
    var onSpeech: (String, [WordTime]) -> Void = { _, _ in }
    /// The current stretch of speech is final; keep it.
    var onSegmentEnd: () -> Void = {}
    var onLevel: (Float) -> Void = { _ in }

    private enum State { case idle, running, finishing }

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private let box = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var state = State.idle
    private var finishCompletion: (() -> Void)?
    private var segmentStart = Date()
    private var firstSeen: [Date] = []
    private var lastText = ""
    private var peakLevel: Float = 0
    private var resultCount = 0

    var isRunning: Bool { state == .running }

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        log("speech permission \(speech.rawValue) (3 = allowed), microphone \(mic ? "allowed" : "denied")")
        return speech == .authorized && mic
    }

    func start() throws {
        guard state == .idle else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Critique", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition unavailable"])
        }
        let input = engine.inputNode
        let box = self.box
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            box.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async {
                self?.peakLevel = max(self?.peakLevel ?? 0, level)
                self?.onLevel(level)
            }
        }
        engine.prepare()
        try engine.start()
        log("listening (on-device: \(recognizer.supportsOnDeviceRecognition), mic format: \(input.outputFormat(forBus: 0)))")
        state = .running
        peakLevel = 0
        resultCount = 0
        beginSegment()
    }

    /// Stops listening but lets the recognizer finish your last words, then calls `done`.
    func finish(_ done: @escaping () -> Void) {
        guard state == .running else { done(); return }
        state = .finishing
        finishCompletion = done
        stopAudio()
        box.request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.completeFinish() }
    }

    /// Stops right away and throws away anything unfinished.
    func stop() {
        if state != .idle {
            log("stopped listening — loudest level \(String(format: "%.2f", peakLevel)) (0–1), \(resultCount) speech results")
        }
        if state == .running { stopAudio() }
        state = .idle
        finishCompletion = nil
        generation += 1
        task?.cancel()
        task = nil
        box.request = nil
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onLevel(0)
    }

    private func completeFinish() {
        guard state == .finishing else { return }
        let done = finishCompletion
        stop()
        done?()
    }

    private func beginSegment() {
        guard let recognizer else { return }
        generation += 1
        let current = generation
        segmentStart = Date()
        firstSeen = []
        lastText = ""
        log("speech segment started")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        box.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcription = result?.bestTranscription
            let isFinal = result?.isFinal ?? false
            if let error { log("speech recognition ended: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.state != .idle else { return }
                if let transcription {
                    self.resultCount += 1
                    // After a pause the recognizer may start over with just the new
                    // sentence. Keep what was said before instead of overwriting it.
                    let text = transcription.formattedString
                    if Self.startedOver(from: self.lastText, to: text) {
                        log("speech restarted after a pause; keeping “\(self.lastText)”")
                        self.onSegmentEnd()
                        self.firstSeen = []
                    }
                    self.lastText = text
                    self.onSpeech(transcription.formattedString, self.wordTimes(transcription))
                }
                guard isFinal || error != nil else { return }
                log("speech segment ended (final: \(isFinal)): “\(transcription?.formattedString ?? "")”")
                self.onSegmentEnd()
                if self.state == .finishing {
                    self.completeFinish()
                    return
                }
                // Recognition stops after a long pause; quietly start listening again.
                self.generation += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 0 : 0.3)) {
                    if self.state == .running { self.beginSegment() }
                }
            }
        }
    }

    /// Uses the recognizer's timestamps when it gives them; otherwise, when each
    /// word first showed up (minus typical recognition delay).
    private func wordTimes(_ transcription: SFTranscription) -> [WordTime] {
        let segments = transcription.segments
        let now = Date()
        while firstSeen.count < segments.count { firstSeen.append(now) }
        let timed = segments.contains { $0.timestamp > 0 }
        return segments.enumerated().map { i, segment in
            WordTime(offset: segment.substringRange.location, length: segment.substringRange.length,
                     time: timed ? segmentStart.addingTimeInterval(segment.timestamp)
                                 : firstSeen[i].addingTimeInterval(-0.5))
        }
    }

    /// True when `new` is a fresh sentence rather than a longer/revised version of `old`.
    nonisolated static func startedOver(from old: String, to new: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
        let a = words(old), b = words(new)
        guard a.count >= 2, !b.isEmpty, b.count < a.count else { return false }
        // Mostly the same words → the recognizer just corrected itself.
        let shared = b.filter(Set(a).contains).count
        if Double(shared) >= Double(b.count) * 0.7 && b.count >= 3 { return false }
        return Array(a.prefix(2)) != Array(b.prefix(2)) && a.first != b.first
    }

    /// Transcribes a recording's audio afterwards — a second, more reliable pass.
    /// Word times are seconds from the start of the file.
    static func transcribe(_ url: URL, timeout: TimeInterval = 25) async -> [(text: String, at: TimeInterval)] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, let recognizer = SFSpeechRecognizer(),
              recognizer.isAvailable else { return [] }
        recognizer.queue = OperationQueue()
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var words: [(text: String, at: TimeInterval)] = []
            var finished = false
            func finish() {
                let done: [(text: String, at: TimeInterval)]? = lock.withLock {
                    if finished { return nil }
                    finished = true
                    return words
                }
                if let done { cont.resume(returning: done) }
            }
            // Each result is one sentence; collect them all.
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let t = result.bestTranscription
                    let ns = t.formattedString as NSString
                    let sentence = t.segments.compactMap { seg -> (text: String, at: TimeInterval)? in
                        guard seg.substringRange.location + seg.substringRange.length <= ns.length else { return nil }
                        return (ns.substring(with: seg.substringRange), seg.timestamp)
                    }
                    lock.withLock { words += sentence }
                }
                if error != nil || result?.isFinal == true { finish() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                task.cancel()
                finish()
            }
        }
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 40))
    }
}

/// Lets the audio thread feed whichever request is current.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }
    func append(_ buffer: AVAudioPCMBuffer) { request?.append(buffer) }
}
