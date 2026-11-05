import AppKit
import Network

/// Whether macOS lets Critique (and the adb server it starts) on the local
/// network. Looking for phones over Bonjour asks for the permission the first
/// time, and fails with "policy denied" if it was turned off.
enum LocalNetwork {
    /// false if macOS denied it, true if it's allowed or we couldn't tell within `timeout`.
    static func isAllowed(timeout: Duration = .seconds(3)) async -> Bool {
        let browser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: nil), using: .tcp)
        let denied = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = Once(done)
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        once.resume(true)
                    }
                default: break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { once.resume(false) }
            }
            browser.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(false)
            }
        }
        browser.cancel()
        return !denied
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Resumes the continuation once, whichever callback gets there first. Unchecked: the field is behind a lock.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.withLock {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
    }
}
