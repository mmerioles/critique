import AppKit
import ScreenCaptureKit

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    static func screenUnderMouse() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Full-resolution screenshot of one display, with Critique's own windows left out.
    static func capture(_ screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw NSError(domain: "Critique", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found"])
        }
        let ourselves = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ourselves, exceptingWindows: [])
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
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
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
