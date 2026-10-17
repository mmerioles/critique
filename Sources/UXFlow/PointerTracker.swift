import AppKit
import QuartzCore

/// Treats your cursor like a finger. While a session runs it notices:
///  - **rest**: the cursor sits on something while you're talking
///  - **click**: you click something
///  - **drawing**: you hold ` and move the cursor to draw on the screen
///  - **hover**: the cursor settles somewhere new (used to log what you hover over)
/// and shows a red ring around the cursor so it's obvious where you're pointing.
@MainActor
final class PointerTracker {
    enum Gesture {
        case rest
        case click
        /// The stroke you drew, in global Cocoa coordinates.
        case drawing([NSPoint])
    }

    /// (gesture, cursor location in global Cocoa coordinates, when the gesture began)
    var onGesture: (Gesture, NSPoint, Date) -> Void = { _, _, _ in }
    /// The cursor settled at a new spot (global Cocoa coordinates).
    var onHover: (NSPoint) -> Void = { _ in }
    /// Resting only counts while you're talking, so a parked cursor doesn't fire.
    var isTalking: () -> Bool = { true }
    /// Areas to ignore, such as UX Flow's own bar.
    var ignore: (NSPoint) -> Bool = { _ in false }

    let markup = Markup()
    private(set) var isDrawing = false
    private var timer: Timer?
    private var clickMonitor: Any?

    private var anchor = NSPoint.zero
    private var anchorSince = Date()
    private var firedHere = false
    private var hoveredHere = false
    private var lastShot: (point: NSPoint, at: Date)?
    private var stroke: [NSPoint] = []
    private var strokeStart = Date()

    private let stillRadius: CGFloat = 12      // wobble allowed while "resting"
    private let hoverTime: TimeInterval = 0.2  // settle this long to count as hovering
    private let restTime: TimeInterval = 0.55  // rest this long (while talking) to point at something
    private let sameSpot: CGFloat = 70         // don't re-capture the same spot
    private let minGap: TimeInterval = 1.2     // at most one capture per this many seconds

    func start() {
        anchor = NSEvent.mouseLocation
        anchorSince = Date()
        firedHere = true // ignore wherever the cursor happens to be at the start
        hoveredHere = false
        lastShot = nil
        isDrawing = false
        markup.show(cursor: anchor)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        isDrawing = false
        markup.hide()
    }

    /// Hold ` → start drawing where the cursor is.
    func beginDrawing() {
        guard timer != nil, !isDrawing else { return } // key repeat sends more presses
        isDrawing = true
        stroke = [NSEvent.mouseLocation]
        strokeStart = Date()
        markup.beginStroke(at: stroke[0])
    }

    /// Release ` → the stroke becomes a capture.
    func endDrawing() {
        guard isDrawing else { return }
        isDrawing = false
        let p = NSEvent.mouseLocation
        stroke.append(p)
        markup.endStroke()
        firedHere = true
        anchor = p
        report(.drawing(stroke), at: p, since: strokeStart)
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let now = Date()
        markup.moveCursor(to: p)

        if isDrawing {
            if let last = stroke.last, hypot(p.x - last.x, p.y - last.y) >= 2 {
                stroke.append(p)
                markup.extendStroke(to: p)
            }
            return
        }

        if hypot(p.x - anchor.x, p.y - anchor.y) > stillRadius {
            anchor = p
            anchorSince = now
            firedHere = false
            hoveredHere = false
            return
        }
        let still = now.timeIntervalSince(anchorSince)
        if !hoveredHere, still >= hoverTime, !ignore(p) {
            hoveredHere = true
            onHover(p)
        }
        guard !firedHere, still >= restTime, isTalking(), !ignore(p) else { return }
        firedHere = true
        if let last = lastShot {
            if hypot(p.x - last.point.x, p.y - last.point.y) < sameSpot { return }
            if now.timeIntervalSince(last.at) < minGap { firedHere = false; return } // try again shortly
        }
        report(.rest, at: p, since: anchorSince)
    }

    private func clicked() {
        let p = NSEvent.mouseLocation
        guard timer != nil, !isDrawing, !ignore(p) else { return }
        firedHere = true
        anchor = p
        report(.click, at: p, since: Date())
    }

    private func report(_ gesture: Gesture, at p: NSPoint, since: Date) {
        lastShot = (p, Date())
        onGesture(gesture, p, since)
    }
}

/// Click-through overlays (one per display) that draw the cursor ring and the
/// red boxes. UX Flow leaves these out of screenshots and draws its own marks
/// there instead; the screen recording does show them.
@MainActor
final class Markup {
    static var red: CGColor { FeedbackWriter.accent }

    private var windows: [MarkupWindow] = []

    func show(cursor: NSPoint) {
        windows = NSScreen.screens.map { MarkupWindow(screen: $0) }
        windows.forEach { $0.orderFrontRegardless() }
        moveCursor(to: cursor)
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    func moveCursor(to p: NSPoint) {
        for window in windows { window.moveRing(to: p) }
    }

    /// Ripple around the cursor: "got it".
    func pulse() {
        windows.first { $0.frame.contains(NSEvent.mouseLocation) }?.pulse()
    }

    private var strokeWindow: MarkupWindow?

    func beginStroke(at p: NSPoint) {
        strokeWindow = windows.first { $0.frame.contains(p) }
        strokeWindow?.beginStroke(at: p)
    }

    func extendStroke(to p: NSPoint) { strokeWindow?.extendStroke(to: p) }

    func endStroke() {
        strokeWindow?.endStroke()
        strokeWindow = nil
    }

    /// Draws a red box (global Cocoa coordinates) that fades after a moment.
    func box(_ rect: CGRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        windows.first { $0.frame.contains(center) }?.drawBox(rect)
    }
}

private final class MarkupWindow: NSPanel {
    private let ring = CAShapeLayer()
    private let ripple = CAShapeLayer()
    private let ringSize: CGFloat = 60

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        contentView = view

        let ringRect = CGRect(x: 0, y: 0, width: ringSize, height: ringSize)
        for layer in [ripple, ring] {
            layer.bounds = ringRect
            layer.path = CGPath(ellipseIn: ringRect, transform: nil)
            layer.strokeColor = Markup.red
            view.layer?.addSublayer(layer)
        }
        ring.fillColor = Markup.red.copy(alpha: 0.14)
        ring.lineWidth = 3
        ring.shadowColor = Markup.red
        ring.shadowRadius = 8
        ring.shadowOpacity = 0.7
        ring.shadowOffset = .zero
        ripple.fillColor = nil
        ripple.lineWidth = 2
        ripple.opacity = 0
    }

    override var canBecomeKey: Bool { false }

    func moveRing(to p: NSPoint) {
        let inside = frame.contains(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = !inside
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        ring.position = local
        ripple.position = local
        CATransaction.commit()
    }

    func pulse() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(group, forKey: "pulse")
    }

    private var stroke: CAShapeLayer?
    private var strokePath = CGMutablePath()

    func beginStroke(at p: NSPoint) {
        let layer = CAShapeLayer()
        layer.frame = contentView?.bounds ?? .zero
        layer.strokeColor = Markup.red
        layer.fillColor = nil
        layer.lineWidth = 4
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.shadowColor = Markup.red
        layer.shadowRadius = 5
        layer.shadowOpacity = 0.6
        layer.shadowOffset = .zero
        contentView?.layer?.insertSublayer(layer, below: ripple)
        strokePath = CGMutablePath()
        strokePath.move(to: local(p))
        stroke = layer
    }

    func extendStroke(to p: NSPoint) {
        strokePath.addLine(to: local(p))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke?.path = strokePath
        CATransaction.commit()
    }

    func endStroke() {
        guard let layer = stroke else { return }
        stroke = nil
        fadeOut(layer, after: 2.5)
    }

    private func local(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }

    private func fadeOut(_ layer: CALayer, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            layer.opacity = 0
            CATransaction.commit()
        }
    }

    func drawBox(_ rect: CGRect) {
        guard let root = contentView?.layer else { return }
        let local = CGRect(x: rect.minX - frame.minX, y: rect.minY - frame.minY, width: rect.width, height: rect.height)
        let box = CAShapeLayer()
        box.frame = local
        box.path = CGPath(roundedRect: CGRect(origin: .zero, size: local.size), cornerWidth: 6, cornerHeight: 6, transform: nil)
        box.strokeColor = Markup.red
        box.fillColor = Markup.red.copy(alpha: 0.07)
        box.lineWidth = 3
        box.shadowColor = Markup.red
        box.shadowRadius = 6
        box.shadowOpacity = 0.5
        box.shadowOffset = .zero
        root.insertSublayer(box, below: ripple)

        // Snap in, hold, fade out.
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.08
        pop.toValue = 1
        pop.duration = 0.18
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.18
        box.add(pop, forKey: "pop")
        box.add(appear, forKey: "appear")
        fadeOut(box, after: 2.2)
    }
}
