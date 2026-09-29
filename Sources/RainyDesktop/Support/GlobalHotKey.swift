import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey -- works
/// while any app is focused and, unlike an NSEvent global monitor, needs no
/// Accessibility permission.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let action: () -> Void
    private static var handlers: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private init(action: @escaping () -> Void) { self.action = action }

    static func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) -> GlobalHotKey? {
        installEventHandlerIfNeeded()
        let hotKey = GlobalHotKey(action: action)
        let id = nextID
        nextID += 1
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5241_494E) /* 'RAIN' */, id: id)
        guard RegisterEventHotKey(keyCode, carbonMods, hotKeyID, GetApplicationEventTarget(), 0, &hotKey.ref) == noErr else {
            debugLog("GlobalHotKey: failed to register keyCode \(keyCode)")
            return nil
        }
        handlers[id] = hotKey
        return hotKey
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            GlobalHotKey.handlers[hotKeyID.id]?.action()
            return noErr
        }, 1, &spec, nil, nil)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
