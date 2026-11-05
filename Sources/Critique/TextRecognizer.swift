import AppKit
import ScreenCaptureKit
import Vision

/// Reads the text in part of a screenshot with Vision OCR. Accessibility can't
/// name things in canvas apps, games, Electron apps that haven't woken up, or
/// phone frames — so when it comes back empty, this reads the words off the pixels.
enum TextRecognizer {
    struct Line {
        let text: String
        /// Image pixels, top-left origin.
        let box: CGRect
    }

    /// `text “Sign up”`, matching the Accessibility labels in `Shot.inside`.
    static func entry(_ text: String) -> String {
        "text “\(text.count > 80 ? text.prefix(80) + "…" : text)”"
    }

    /// True when Accessibility found nothing worth telling the agent about: no
    /// controls, and nothing with a name (just "group", "image", "list"…).
    static func wanted(for elements: [ElementLocator.Element]) -> Bool {
        !elements.contains { $0.isInteractive || $0.label.contains("“") }
    }

    /// Lines of text in `region` of the image (image pixels, top-left origin),
    /// top to bottom. Tiny fragments are dropped and repeats removed.
    static func read(_ image: CGImage, in region: CGRect, max limit: Int = 8) async -> [Line] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = region.integral.intersection(bounds)
        guard crop.width >= 8, crop.height >= 8, let cropped = image.cropping(to: crop) else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [Line] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
            } catch {
                log("text recognition failed: \(error.localizedDescription)")
                return []
            }
            var lines: [Line] = []
            var seen = Set<String>()
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard text.count >= 2, text.contains(where: { $0.isLetter || $0.isNumber }),
                      seen.insert(text.lowercased()).inserted else { continue }
                // Vision boxes are normalized with a bottom-left origin, relative to the crop.
                let b = observation.boundingBox
                let box = CGRect(x: crop.minX + b.minX * crop.width, y: crop.minY + (1 - b.maxY) * crop.height,
                                 width: b.width * crop.width, height: b.height * crop.height)
                lines.append(Line(text: text, box: box))
            }
            return Array(lines.sorted { abs($0.box.minY - $1.box.minY) > 4 ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
                              .prefix(limit))
        }.value
    }

    /// `text “…”` entries for everything readable in `region`, for `Shot.inside`.
    static func entries(in image: CGImage, region: CGRect, max limit: Int = 8) async -> [String] {
        await read(image, in: region, max: limit).map { entry($0.text) }
    }

    /// What's written at a point (a tapped or clicked spot): the line nearest the
    /// point becomes `element`, the other lines around it go in `inside`.
    static func around(_ point: CGPoint, in image: CGImage, size: CGSize) async -> (element: String?, inside: [String]) {
        let region = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        let lines = await read(image, in: region)
        guard !lines.isEmpty else { return (nil, []) }
        func distance(_ line: Line) -> CGFloat {
            let dx = max(line.box.minX - point.x, 0, point.x - line.box.maxX)
            let dy = max(line.box.minY - point.y, 0, point.y - line.box.maxY)
            return dx * dx + dy * dy
        }
        let nearest = lines.min { distance($0) < distance($1) }!
        // Only call it the element when the finger or cursor was actually on (or right by) it.
        let reach = max(nearest.box.height, size.height * 0.2)
        guard distance(nearest) <= reach * reach else { return (nil, lines.map { entry($0.text) }) }
        return (entry(nearest.text), lines.filter { $0.text != nearest.text }.map { entry($0.text) })
    }

    /// Reads what's written around the cursor, from a capture of just that bit of
    /// the screen. `point` is global, top-left origin; `size` is in points.
    static func textNear(_ point: CGPoint, on screen: NSScreen, size: CGSize = CGSize(width: 280, height: 90)) async -> (element: String?, inside: [String]) {
        guard Feature.screen.isOn else { return (nil, []) }
        let scale = screen.backingScaleFactor
        let primaryHeight = NSScreen.screens[0].frame.height
        // Screen-local, top-left origin, in points.
        let local = CGPoint(x: point.x - screen.frame.minX, y: point.y - (primaryHeight - screen.frame.maxY))
        let rect = CGRect(x: local.x - size.width / 2, y: local.y - size.height / 2, width: size.width, height: size.height)
            .intersection(CGRect(origin: .zero, size: screen.frame.size))
        guard rect.width >= 8, rect.height >= 8, let image = try? await ScreenCapture.capture(screen, rect: rect) else { return (nil, []) }
        let at = CGPoint(x: (local.x - rect.minX) * scale, y: (local.y - rect.minY) * scale)
        return await around(at, in: image, size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
}

extension ScreenCapture {
    /// Screenshot of one part of a display (`rect` in the screen's own points, top-left
    /// origin), without Critique's pill and overlays. Much cheaper than the whole screen.
    static func capture(_ screen: NSScreen, rect: CGRect) async throws -> CGImage {
        guard Feature.screen.isOn else {
            throw NSError(domain: "Critique", code: 5, userInfo: [NSLocalizedDescriptionKey: "Screen recording is turned off in Critique"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw NSError(domain: "Critique", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found"])
        }
        let overlays = content.windows.filter {
            $0.owningApplication?.processID == getpid() && !keepWindows.contains($0.windowID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: overlays)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
