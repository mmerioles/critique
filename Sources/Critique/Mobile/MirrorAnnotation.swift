import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import QuartzCore

/// Makes the phone mirror a critique surface. While a phone critique is recording
/// and the mirror is showing, hold ` with the mouse over the phone's picture and
/// move to draw on it, just like drawing on the desktop. Each stroke becomes a
/// screenshot: a frame from the phone recording with the stroke drawn on it, and
/// a [#n] marker in your words. With "Tap through" on, clicks and drags on the
/// picture tap and swipe on the phone.
///
/// A desktop session wins: while one runs it holds the ` key, and the mirror
/// gets it back when the session ends.
@MainActor
final class MirrorAnnotation: ObservableObject {
    static let shared = MirrorAnnotation()

    /// One stroke drawn on the mirror: where it went in the mirror's picture
    /// (pixels, top-left origin), how big the picture was then, and when.
    struct Drawing {
        let stroke: [CGPoint]
        let size: CGSize
        let began: Date
        let ended: Date
    }

    /// Clicks and drags on the mirror go to the phone as taps and swipes.
    @Published var tapThrough: Bool = UserDefaults.standard.bool(forKey: "mirror.tapThrough") {
        didSet { UserDefaults.standard.set(tapThrough, forKey: "mirror.tapThrough") }
    }

    private let mirror = PhoneMirror.shared
    private var recording = false      // a phone critique is in progress
    private var desktopActive = false  // a desktop session has the ` key
    private var keyID: UInt32?
    private var watchers: Set<AnyCancellable> = []

    // The stroke being drawn, in the display view's coordinates.
    private var strokeLayer: CAShapeLayer?
    private var path = CGMutablePath()
    private var points: [CGPoint] = []
    private var picture = CGRect.zero   // where the phone's picture sits in the view
    private var pictureSize = CGSize.zero
    private var strokeStart = Date()
    private var timer: Timer?

    // Tap through
    private var clickMonitor: Any?
    private var press: (point: CGPoint, at: Date)?
    private var screenSize: CGSize?

    private let maxDrawings = 20

    private init() {
        // The key is only worth holding while there's a picture to draw on.
        mirror.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.mirrorChanged() }.store(in: &watchers)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type, window = event.window, at = event.locationInWindow
            // AppKit calls event monitors on the main thread.
            let taken = MainActor.assumeIsolated { self?.forward(type, in: window, at: at) ?? false }
            return taken ? nil : event
        }
    }

    // MARK: When to hold the key

    /// A phone critique started: hold ` while the mirror is showing.
    func begin() {
        recording = true
        press = nil
        sync()
    }

    /// The phone critique is being sent, or was cancelled.
    func end() {
        recording = false
        sync()
    }

    /// A desktop session is starting (it takes the ` key) or has ended (the mirror gets it back).
    func desktopSession(active: Bool) {
        desktopActive = active
        sync()
    }

    private func mirrorChanged() {
        if mirror.state == .live, let serial = mirror.serial {
            // For tap through: `input tap` wants the phone's own pixels, not the stream's.
            Task { screenSize = await ADB.screenSize(serial) }
        } else {
            screenSize = nil
        }
        sync()
    }

    private var wantsKey: Bool { recording && !desktopActive && mirror.isOn }

    private func sync() {
        if wantsKey, keyID == nil {
            keyID = HotKeys.shared.register(kVK_ANSI_Grave, 0, onRelease: { [weak self] in self?.released() }) { [weak self] in
                self?.pressed()
            }
            if keyID == nil { log("mirror: couldn't take the ` key for drawing") }
        } else if !wantsKey, let id = keyID {
            HotKeys.shared.unregister(id)
            keyID = nil
            cancelStroke()
        }
    }

    // MARK: Drawing

    /// Hold ` over the phone's picture → start a stroke there.
    private func pressed() {
        guard strokeLayer == nil, wantsKey else { return } // key repeat sends more presses
        guard let spot = mouseOnPicture() else { return }
        picture = spot.picture
        pictureSize = spot.size
        points = [spot.point]
        strokeStart = Date()
        path = CGMutablePath()
        path.move(to: spot.point)

        let display = mirror.display
        let layer = CAShapeLayer()
        layer.frame = display.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.strokeColor = Markup.red
        layer.fillColor = nil
        layer.lineWidth = 4
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.shadowColor = Markup.red
        layer.shadowRadius = 5
        layer.shadowOpacity = 0.6
        layer.shadowOffset = .zero
        display.layer?.addSublayer(layer)
        strokeLayer = layer

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() } // scheduled here, so it fires on the main run loop
        }
    }

    private func tick() {
        guard strokeLayer != nil, let p = mouseInDisplay() else { return }
        let q = Self.clamp(p, to: picture)
        guard let last = points.last, hypot(q.x - last.x, q.y - last.y) >= 2 else { return }
        points.append(q)
        path.addLine(to: q)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer?.path = path
        CATransaction.commit()
    }

    /// Release ` → the stroke goes into the critique.
    private func released() {
        guard let layer = strokeLayer else { return }
        timer?.invalidate()
        timer = nil
        strokeLayer = nil
        if let p = mouseInDisplay() { points.append(Self.clamp(p, to: picture)) }
        fadeOut(layer)
        record()
    }

    private func record() {
        let drawn = Self.bounds(of: points)
        guard drawn.width > 10 || drawn.height > 10 else { return } // a tap, not a drawing
        guard case .recording = Mobile.shared.phase, let recording = Mobile.shared.recording,
              recording.drawings.count < maxDrawings, picture.width > 0, picture.height > 0 else { return }
        // View points (bottom-left origin) → the picture's pixels (top-left origin).
        let picture = picture, size = pictureSize
        let stroke = points.map { p in
            CGPoint(x: (p.x - picture.minX) / picture.width * size.width,
                    y: (picture.maxY - p.y) / picture.height * size.height)
        }
        recording.drawings.append(Drawing(stroke: stroke, size: size, began: strokeStart, ended: Date()))
    }

    private func cancelStroke() {
        timer?.invalidate()
        timer = nil
        strokeLayer?.removeFromSuperlayer()
        strokeLayer = nil
        points = []
    }

    private func fadeOut(_ layer: CALayer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            layer.opacity = 0
            CATransaction.commit()
        }
    }

    // MARK: Where the mouse is

    /// The mouse, if it's over the phone's picture (inline on the Mobile page or in
    /// the full-screen window, and nothing on top): the point in the display view,
    /// the picture's frame in that view, and the picture's size in pixels.
    private func mouseOnPicture() -> (point: CGPoint, picture: CGRect, size: CGSize)? {
        let display = mirror.display
        guard mirror.state == .live, let size = mirror.videoSize, let window = display.window, window.isVisible else { return nil }
        let at = NSEvent.mouseLocation
        guard NSWindow.windowNumber(at: at, belowWindowWithWindowNumber: 0) == window.windowNumber else { return nil }
        let p = display.convert(window.convertPoint(fromScreen: at), from: nil)
        let picture = Self.fit(size, in: display.bounds)
        guard picture.contains(p) else { return nil }
        return (p, picture, size)
    }

    private func mouseInDisplay() -> CGPoint? {
        let display = mirror.display
        guard let window = display.window else { return nil }
        return display.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    /// Where a picture of `size` sits in `bounds`, scaled to fit and centred (how
    /// the video layer shows it). Portrait or landscape.
    static func fit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    // MARK: Tap through

    /// A click on the picture taps the phone there; a drag swipes, and holding
    /// still long-presses. Returns true to swallow the event, so the mirror's own
    /// double-click (full screen) stays out of the way.
    private func forward(_ type: NSEvent.EventType, in eventWindow: NSWindow?, at location: CGPoint) -> Bool {
        let display = mirror.display
        guard tapThrough, strokeLayer == nil, mirror.state == .live, let size = mirror.videoSize, let screen = screenSize,
              let window = display.window, eventWindow === window else { return false }
        let picture = Self.fit(size, in: display.bounds)
        let p = display.convert(location, from: nil)
        switch type {
        case .leftMouseDown:
            // A click on a window that isn't key brings it forward first.
            guard picture.contains(p), window.isKeyWindow else { press = nil; return false }
            press = (p, Date())
        case .leftMouseDragged:
            guard press != nil else { return false }
        case .leftMouseUp:
            guard let press else { return false }
            self.press = nil
            guard let serial = mirror.serial else { return true }
            let from = Self.phonePoint(press.point, picture: picture, video: size, screen: screen)
            let to = Self.phonePoint(Self.clamp(p, to: picture), picture: picture, video: size, screen: screen)
            let held = Date().timeIntervalSince(press.at)
            let moved = hypot(p.x - press.point.x, p.y - press.point.y) >= 8
            let command = !moved && held < 0.4
                ? "input tap \(Int(from.x)) \(Int(from.y))"
                : "input swipe \(Int(from.x)) \(Int(from.y)) \(Int(to.x)) \(Int(to.y)) \(Int(min(max(held, 0.05), 1.5) * 1000))"
            Task { _ = await ADB.shell(serial, command) }
        default:
            return false
        }
        return true
    }

    /// A point on the picture → the phone's own pixels in its current orientation
    /// (`screen` is its natural size; the stream says which way it's turned).
    private static func phonePoint(_ p: CGPoint, picture: CGRect, video: CGSize, screen: CGSize) -> CGPoint {
        let fx = (p.x - picture.minX) / picture.width, fy = (picture.maxY - p.y) / picture.height
        let landscape = video.width > video.height
        let w = landscape ? max(screen.width, screen.height) : min(screen.width, screen.height)
        let h = landscape ? min(screen.width, screen.height) : max(screen.width, screen.height)
        return CGPoint(x: min(max(fx, 0), 1) * w, y: min(max(fy, 0), 1) * h)
    }
}

extension Recording {
    /// Adds the strokes drawn on the mirror to the tap screenshots, numbered with
    /// them in time order. Each stroke gets a frame from the recording from when
    /// it was finished, with the stroke scaled onto it so FeedbackWriter draws it.
    func withDrawings(_ taps: [Shot], clockStart: Date, asset: AVURLAsset,
                      apps: [(at: Date, package: String, activity: String)]) async -> [Shot] {
        guard !drawings.isEmpty else { return taps }
        let duration = (try? await asset.load(.duration).seconds) ?? .infinity
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero

        var shots = taps
        for drawing in drawings {
            // The screen as the stroke was finished (the mirror runs a touch behind the phone).
            let t = min(max(0, drawing.ended.timeIntervalSince(clockStart) - 0.1), max(duration - 0.1, 0))
            guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let app = apps.last { $0.at <= drawing.began } ?? apps.first
            var shot = Shot(number: 0, kind: .drawing, image: image, app: app?.package,
                            window: app.map { $0.activity.split(separator: ".").last.map(String.init) ?? $0.activity })
            let w = CGFloat(image.width), h = CGFloat(image.height)
            // Recording and mirror in the same orientation: scale the stroke onto the frame.
            if (w > h) == (drawing.size.width > drawing.size.height) {
                let stroke = drawing.stroke.map { CGPoint(x: $0.x / drawing.size.width * w, y: $0.y / drawing.size.height * h) }
                let pad = max(w, h) * 0.01
                shot.stroke = stroke
                shot.region = MirrorAnnotation.bounds(of: stroke).insetBy(dx: -pad, dy: -pad)
                    .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            }
            shot.time = drawing.began
            shots.append(shot)
        }
        return Self.renumbered(shots)
    }

    /// Shots in the order they happened, numbered 1, 2, 3…
    private static func renumbered(_ shots: [Shot]) -> [Shot] {
        shots.sorted { $0.time < $1.time }.enumerated().map { i, s in
            Shot(number: i + 1, kind: s.kind, image: s.image, region: s.region, point: s.point, app: s.app,
                 window: s.window, element: s.element, stroke: s.stroke, inside: s.inside, time: s.time)
        }
    }
}
