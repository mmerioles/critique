import AVFoundation
@preconcurrency import Speech

/// After a session, re-transcribes your voice from the recording. This is
/// usually more accurate than live dictation because it hears everything at once.
///
/// Uses Apple's newer long-form transcriber on macOS 26 (the one behind Notes and
/// Voice Memos), and falls back to the classic recognizer on older systems.
enum Transcriber {
    struct Word {
        let text: String
        /// Seconds from the start of the audio.
        let at: TimeInterval
    }

    /// Words developers say that dictation tends to mishear ("read me" → README).
    static let vocabulary = [
        "README", "Claude Code", "Claude", "Critique", "MCP", "UI", "UX", "CSS", "HTML", "JSON", "API",
        "GitHub", "repo", "commit", "push", "pull request", "PR", "Xcode", "Swift", "SwiftUI", "macOS",
        "iOS", "localhost", "navbar", "sidebar", "modal", "dropdown", "tooltip", "padding", "margin",
        "flexbox", "hover", "onboarding", "Wispr Flow", "Figma", "Tailwind", "React", "Next.js", "npm",
    ]

    /// Copies just the audio out of a screen recording, so agents can listen again.
    static func exportAudio(from video: URL, to destination: URL) async -> Bool {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: video), presetName: AVAssetExportPresetAppleM4A) else { return false }
        do {
            try await export.export(to: destination, as: .m4a)
            return true
        } catch {
            log("couldn't extract audio: \(error.localizedDescription)")
            return false
        }
    }

    /// Transcribes an audio file. `hints` are names seen during the session
    /// (apps, buttons, window titles) to help with unusual words.
    static func transcribe(_ audio: URL, hints: [String]) async -> (words: [Word], engine: String)? {
        let hints = Array(Set(vocabulary + hints)).filter { !$0.isEmpty && $0.count <= 40 }.prefix(100).map { $0 }
        #if compiler(>=6.2)
        if #available(macOS 26, *), let words = await longForm(audio, hints: hints), !words.isEmpty {
            return (words, "Apple SpeechTranscriber")
        }
        #endif
        let words = await Dictation.transcribe(audio, hints: hints).map { Word(text: $0.text, at: $0.at) }
        return words.isEmpty ? nil : (words, "Apple SFSpeechRecognizer")
    }

    /// Downloads the on-device speech model ahead of time so sending never waits on it.
    static func prepare() async {
        #if compiler(>=6.2)
        if #available(macOS 26, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            let module = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    log("downloading the speech model")
                    try await request.downloadAndInstall()
                }
            } catch {
                log("speech model unavailable: \(error.localizedDescription)")
            }
        }
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    private static func longForm(_ url: URL, hints: [String]) async -> [Word]? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try? await analyzer.setContext(context)

            let collector = Task { () -> [Word] in
                var words: [Word] = []
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        let piece = String(result.text[run.range].characters)
                        let at = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]?.start.seconds
                            ?? result.range.start.seconds
                        for token in piece.split(whereSeparator: \.isWhitespace) {
                            words.append(Word(text: String(token), at: at))
                        }
                    }
                }
                return words
            }
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch {
            log("long-form transcription failed: \(error.localizedDescription)")
            return nil
        }
    }
    #endif
}
