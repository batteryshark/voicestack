import Carbon
import FloatingVoiceCore

/// One system-wide hotkey through Carbon's RegisterEventHotKey, which needs no Accessibility permission. Used for
/// Send in manual send mode; registered only while that mode is on.
@MainActor
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered: Hotkey?
    /// Called on the main thread when the hotkey is pressed.
    var onPress: (() -> Void)?
    private static var nextID: UInt32 = 0
    private let id: UInt32
    private let purpose: String
    init(purpose: String = "Send") {
        Self.nextID += 1; id = Self.nextID; self.purpose = purpose
    }

    /// Register `spec` (unregistering any previous one). Returns an error message, or nil on success.
    func register(_ spec: String) -> String? {
        unregister()
        guard let key = Hotkey.parse(spec) else { return "Not a hotkey: \(spec)" }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
                    guard pressed.signature == 0x46_56_53_44, pressed.id == owner.id else { return OSStatus(eventNotHandledErr) }
                    if owner.registered != nil { owner.onPress?() }
                    return noErr
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return "Could not install the hotkey handler (\(status))" }
        }
        let id = EventHotKeyID(signature: OSType(0x46_56_53_44), id: self.id) // "FVSD"
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { ref = nil; return "\(purpose) shortcut \(key.display) is unavailable (\(status)); the \(purpose) button still works." }
        registered = key
        return nil
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }
}
