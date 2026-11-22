import Carbon.HIToolbox

@MainActor
final class HotKey {
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var handlerRef: EventHandlerRef?
    private static let signature = OSType(0x5749_5350)

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init?(
        id: UInt32 = 1,
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey),
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        guard Self.installHandler() else { return nil }
        let spec = EventHotKeyID(signature: Self.signature, id: id)
        guard RegisterEventHotKey(keyCode, modifiers, spec, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
        Self.actions[id] = action
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.actions[id] = nil
    }

    private static func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            guard status == noErr else { return status }
            let id = pressed.id
            Task { @MainActor in HotKey.actions[id]?() }
            return noErr
        }
        return InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef) == noErr
    }
}
