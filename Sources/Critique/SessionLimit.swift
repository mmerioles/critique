import Foundation

/// The longest a critique may run. A forgotten session used to record for hours
/// and leave a 24 GB file behind; now it sends itself (or cancels, if nothing
/// was said or pointed at) when the limit is up.
enum SessionLimit: Int, CaseIterable, Identifiable {
    case five = 5, ten = 10, twenty = 20, thirty = 30

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    var name: String { "\(rawValue) min" }

    static var current: SessionLimit {
        get { SessionLimit(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .ten }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    private static let key = "session.maxMinutes"
}

extension CritiqueController {
    /// Warns in the pill a minute before the limit, then sends or cancels at the limit.
    /// Call when a session starts; `disarmCap()` when it ends.
    func armCap() {
        disarmCap()
        let limit = SessionLimit.current
        let warn = DispatchWorkItem { [weak self] in
            guard let self, self.session.isActive else { return }
            self.session.hint = "1 min left — critiques stop at \(limit.name)"
        }
        let cap = DispatchWorkItem { [weak self] in
            guard let self, self.session.isActive else { return }
            self.session.hint = nil
            let said = !self.session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if said || !self.session.shots.isEmpty {
                log("critique hit the \(limit.name) limit — sending")
                self.send()
            } else {
                log("critique hit the \(limit.name) limit with nothing to send — cancelling")
                self.cancel()
                self.notice("Stopped after \(limit.name) — nothing was said or pointed at.", seconds: 3)
            }
        }
        capTimers = [warn, cap]
        DispatchQueue.main.asyncAfter(deadline: .now() + limit.seconds - 60, execute: warn)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit.seconds, execute: cap)
    }

    func disarmCap() {
        for work in capTimers { work.cancel() }
        capTimers = []
        session.hint = nil
    }
}
