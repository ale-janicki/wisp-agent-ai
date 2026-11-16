import Carbon.HIToolbox

@MainActor
final class HotKey {
    private static var action: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init?(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey),
        action: @escaping @MainActor () -> Void
    ) {
        HotKey.action = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, _ in
            Task { @MainActor in HotKey.action?() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef) == noErr else {
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x5749_5350), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
    }
}
