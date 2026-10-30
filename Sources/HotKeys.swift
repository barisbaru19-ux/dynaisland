import AppKit
import Carbon

extension Notification.Name {
    static let dynaHotKey = Notification.Name("DynaIsland.HotKey")
}

/// Global keyboard shortcuts. Carbon hot keys need no permission at all.
enum HotKey: UInt32, CaseIterable {
    case openIsland = 1
    case clipboard = 2

    var keyCode: UInt32 {
        switch self {
        case .openIsland: return UInt32(kVK_Space)
        case .clipboard: return UInt32(kVK_ANSI_V)
        }
    }

    /// ⌃⌥: rarely used by other apps (⌥Space and ⌥⌘V often are).
    var modifiers: UInt32 { UInt32(controlKey | optionKey) }

    var label: String {
        switch self {
        case .openIsland: return "⌃⌥ Space"
        case .clipboard: return "⌃⌥ V"
        }
    }

    var title: String {
        switch self {
        case .openIsland: return "Buka atau tutup island"
        case .clipboard: return "Riwayat clipboard"
        }
    }
}

enum HotKeys {
    private static var references: [EventHotKeyRef] = []
    private static var handlerInstalled = false
    /// Shortcuts another app already uses (couldn't be registered).
    private(set) static var taken: Set<HotKey> = []

    static func register() {
        installHandlerOnce()
        unregister()
        for key in HotKey.allCases {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4459_4E41), id: key.rawValue)   // "DYNA"
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference = reference {
                references.append(reference)
            } else {
                taken.insert(key)
            }
        }
    }

    static func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        taken.removeAll()
    }

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            NotificationCenter.default.post(name: .dynaHotKey, object: nil, userInfo: ["id": id.id])
            return noErr
        }, 1, &pressed, nil, nil)
    }
}
