import Foundation

/// Parts of Critique you can switch off in Permissions. macOS doesn't let an app
/// give back a permission, so "off" means Critique simply stops using it.
enum Feature: String, CaseIterable {
    case screen         // screen recording + screenshots
    case voice          // microphone + speech recognition
    case doubleTap      // right ⌥ double-tap (Input Monitoring)
    case accessibility  // element names, hover/click log, typing into Claude Code

    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
    private var key: String { "feature.\(rawValue)" }
}
