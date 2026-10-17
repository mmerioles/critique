import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys via Carbon. They need no Accessibility permission, and
/// while registered the key goes to UX Flow instead of the app underneath.
final class HotKeys {
    static let shared = HotKeys()

    private struct Handlers {
        let press: () -> Void
        let release: (() -> Void)?
    }

    private var handlers: [UInt32: Handlers] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(_ keyCode: Int, _ modifiers: Int, onRelease: (() -> Void)? = nil,
                  handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5558_4657), id: id) // 'UXFW'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        handlers[id] = Handlers(press: handler, release: onRelease)
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                guard let handlers = HotKeys.shared.handlers[id] else { return }
                released ? handlers.release?() : handlers.press()
            }
            return noErr
        }, specs.count, specs, nil, nil)
    }
}
