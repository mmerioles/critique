import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a finished session into a folder in the inbox.
enum FeedbackWriter {
    struct Input: @unchecked Sendable {
        let notes: String
        let shots: [Shot]
        /// Every word you said, with its time.
        var words: [SpokenWord] = []
        /// What you hovered and clicked.
        var interactions: [Interaction] = []
        /// Screen recording of the session, if there is one.
        var video: URL? = nil
        /// Time zero for the timeline (when the recording started).
        var clockStart = Date()
        var duration: TimeInterval = 0
    }

    static func write(_ input: Input) throws -> (dir: URL, record: FeedbackRecord) {
        let now = Date()
        var id = Inbox.newID(for: now)
        var dir = Inbox.root.appendingPathComponent(id)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            id = "\(Inbox.newID(for: now))-\(suffix)"; suffix += 1
            dir = Inbox.root.appendingPathComponent(id)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var shots: [FeedbackRecord.ShotRecord] = []
        for shot in input.shots {
            var record = FeedbackRecord.ShotRecord(number: shot.number, kind: shot.kind.rawValue,
                                                   file: "\(shot.number)-\(shot.kind.rawValue).png",
                                                   app: shot.app, window: shot.window)
            record.element = shot.element
            record.at = max(0, shot.time.timeIntervalSince(input.clockStart))
            record.said = said(around: shot, in: input)
            record.inside = shot.inside.isEmpty ? nil : shot.inside
            // The whole screen, with your stroke drawn on it.
            var image = shot.image
            if let stroke = shot.stroke, stroke.count > 1 {
                image = annotate(image, stroke: stroke, number: shot.number) ?? image
            }
            if let region = shot.region {
                record.region = [Int(region.minX), Int(region.minY), Int(region.width), Int(region.height)]
            }
            try writePNG(image, to: dir.appendingPathComponent(record.file))
            shots.append(record)
        }

        var record = FeedbackRecord(id: id, createdAt: now, notes: input.notes, shots: shots)
        var videoURL: URL?
        if let video = input.video {
            let dest = dir.appendingPathComponent("recording.mov")
            if (try? FileManager.default.moveItem(at: video, to: dest)) != nil {
                record.video = dest.lastPathComponent
                record.duration = input.duration
                videoURL = dest
            }
        }
        record.timeline = timeline(input, shots: shots, video: videoURL, dir: dir)
        try Inbox.save(record, in: dir)
        return (dir, record)
    }

    static let accent = CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)

    /// Lines up what you said, hovered, clicked, and captured on the recording's clock,
    /// and pulls frames from the recording for moments that have no screenshot.
    private static func timeline(_ input: Input, shots: [FeedbackRecord.ShotRecord], video: URL?, dir: URL) -> [FeedbackRecord.Moment] {
        func at(_ date: Date) -> Double { max(0, date.timeIntervalSince(input.clockStart)) }
        var moments: [FeedbackRecord.Moment] = []

        // Your words, grouped into phrases at pauses.
        var phrase: [SpokenWord] = []
        func flush() {
            let text = phrase.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if let first = phrase.first, !text.isEmpty {
                moments.append(.init(at: at(first.time), kind: "said", text: text))
            }
            phrase = []
        }
        for word in input.words {
            // Break at long pauses (recognizer timing is bursty, so short gaps don't count).
            if let last = phrase.last, word.time.timeIntervalSince(last.time) > 2.5 || phrase.count >= 30 { flush() }
            phrase.append(word)
            if let end = word.text.last, ".?!".contains(end) { flush() } // and at sentence ends
        }
        flush()

        for interaction in input.interactions {
            let t = at(interaction.time)
            // A click that got its own screenshot is already in the timeline.
            if interaction.kind == .click,
               shots.contains(where: { $0.kind == "click" && $0.element == interaction.label && abs(($0.at ?? 0) - t) < 1 }) { continue }
            moments.append(.init(at: t, kind: interaction.kind.rawValue, text: interaction.label))
        }
        for shot in shots where shot.kind != "screen" || shot.number > 1 {
            var text = "#\(shot.number) "
            if shot.kind == "drawing" {
                let inside = shot.inside ?? []
                text += inside.isEmpty ? "drew on the screen" : "drew around \(inside.joined(separator: ", "))"
            } else {
                if let element = shot.element {
                    text += "\(FeedbackRecord.label(shot.kind).lowercased()) \(element)"
                } else {
                    text += shot.kind == "click" ? "clicked here" : "pointing here"
                }
            }
            moments.append(.init(at: shot.at ?? 0, kind: "shot", text: text, shot: shot.number))
        }
        moments.sort { $0.at < $1.at }

        // Frames for spoken phrases and interactions that no screenshot covers.
        if let video {
            let shotTimes = moments.filter { $0.kind == "shot" }.map(\.at)
            var taken: [Double] = []
            var wanted: [Int] = []
            for (i, m) in moments.enumerated() where m.kind != "shot" && wanted.count < 12 {
                let t = m.at + 0.2
                if shotTimes.contains(where: { abs($0 - t) < 1.2 }) || taken.contains(where: { abs($0 - t) < 1.5 }) { continue }
                taken.append(t)
                wanted.append(i)
            }
            let frames = extractFrames(from: video, at: wanted.map { moments[$0].at + 0.2 }, into: dir)
            for (i, file) in zip(wanted, frames) { moments[i].frame = file }
        }
        return moments
    }

    /// Grabs still frames from the recording. Returns file names (nil where a frame couldn't be read).
    private static func extractFrames(from video: URL, at times: [Double], into dir: URL) -> [String?] {
        guard !times.isEmpty else { return [] }
        let folder = dir.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1800, height: 1800)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        var results = [String?](repeating: nil, count: times.count)
        let lock = NSLock()
        let group = DispatchGroup()
        let requested = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        for _ in times { group.enter() }
        generator.generateCGImagesAsynchronously(forTimes: requested) { requestedTime, image, _, _, _ in
            defer { group.leave() }
            guard let image, let index = requested.firstIndex(where: { $0.timeValue == requestedTime }) else { return }
            let name = "frames/\(FeedbackRecord.clock(times[index], tenths: true).replacingOccurrences(of: ":", with: "-")).jpg"
            if (try? writeJPEG(image, to: dir.appendingPathComponent(name))) != nil {
                lock.withLock { results[index] = name }
            }
        }
        _ = group.wait(timeout: .now() + 15)
        return results
    }

    /// The words you said while pointing at this shot (until the next one).
    private static func said(around shot: Shot, in input: Input) -> String? {
        guard shot.kind != .screen || shot.number > 1 else { return nil }
        let next = input.shots.map(\.time).filter { $0 > shot.time }.min() ?? .distantFuture
        let words = input.words.filter { $0.time >= shot.time.addingTimeInterval(-0.25) && $0.time < next }.prefix(16)
        let text = words.map(\.text).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Draws the stroke you drew with ` onto the screenshot.
    static func annotate(_ image: CGImage, stroke: [CGPoint], number: Int) -> CGImage? {
        let h = CGFloat(image.height)
        guard let ctx = context(for: image) else { return nil }
        let unit = max(CGFloat(image.width) / 1000, 1)
        let points = stroke.map { CGPoint(x: $0.x, y: h - $0.y) }
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(3.5 * unit)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: 4 * unit, color: accent.copy(alpha: 0.6))
        ctx.addLines(between: points)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0)
        let start = points[0]
        drawBadge(number, at: CGPoint(x: start.x - 14 * unit, y: start.y + 14 * unit), unit: unit, in: ctx,
                  size: CGSize(width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func context(for image: CGImage) -> CGContext? {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    private static func drawBadge(_ number: Int, at p: CGPoint, unit: CGFloat, in ctx: CGContext, size: CGSize) {
        let d = 22 * unit
        let center = CGPoint(x: min(max(p.x, d / 2), size.width - d / 2),
                             y: min(max(p.y, d / 2), size.height - d / 2))
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))

        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, d * 0.55, nil)!
        let text = NSAttributedString(string: "\(number)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: center.x - b.width / 2 - b.minX, y: center.y - b.height / 2 - b.minY)
        CTLineDraw(line, ctx)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Critique", code: 3, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Critique", code: 3, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Critique", code: 3, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Critique", code: 3, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
        }
    }
}
