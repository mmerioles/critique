import AppKit
import ScreenCaptureKit

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    static func screenUnderMouse() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Critique windows that *should* appear in screenshots (the main window), so
    /// you can critique Critique itself. The pill and red overlays never do.
    nonisolated(unsafe) static var keepWindows: Set<CGWindowID> = []

    /// Full-resolution screenshot of one display, without Critique's pill and overlays.
    static func capture(_ screen: NSScreen) async throws -> CGImage {
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
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// App name and window title at a point (global, top-left origin), or of the
    /// frontmost app when `point` is nil. Gives the agent "Safari — localhost:3000".
    static func windowContext(at point: CGPoint?) -> (app: String?, title: String?) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return (NSWorkspace.shared.frontmostApplication?.localizedName, nil)
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for info in list { // ordered front to back
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != getpid() || keepWindows.contains(info[kCGWindowNumber as String] as? CGWindowID ?? 0),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let matches = point.map { bounds.contains($0) } ?? (pid == frontPID)
            if matches {
                let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return (info[kCGWindowOwnerName as String] as? String, title)
            }
        }
        return (NSWorkspace.shared.frontmostApplication?.localizedName, nil)
    }

    /// Converts a point in a screen's local, top-left coordinates to global CG coordinates.
    static func globalPoint(_ local: CGPoint, on screen: NSScreen) -> CGPoint {
        let primaryHeight = NSScreen.screens[0].frame.height
        return CGPoint(x: screen.frame.minX + local.x, y: primaryHeight - screen.frame.maxY + local.y)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
