import CoreAudio
import Foundation
import WispCore

enum AudioDevices {
    struct Device {
        var id: AudioObjectID
        var uid: String
        var name: String
    }

    static func defaultInputName() -> String? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)?.name
    }

    static func defaultOutput() -> Device? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Where the default output goes: its transport (a four-char code, e.g. "bltn", "bluetooth" as "blue") and whether it is
    /// the Mac's own speakers (built-in transport, and not the headphone jack when the data source says so).
    struct OutputRoute {
        var transport: String
        var isBuiltInSpeakers: Bool
        /// Device UID plus data source: identifies the route for the voice processing retry gate.
        var key: String
    }

    static func outputRoute() -> OutputRoute? {
        guard let device = defaultOutput(),
              let transport = uint32(device.id, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        else { return nil }
        // 'ispk' = internal speaker, 'hdpn' = headphones on the jack; unreadable on devices with a single output.
        let source = uint32(device.id, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        let speakers = EchoCancelPolicy.isBuiltInSpeakers(
            builtInTransport: transport == kAudioDeviceTransportTypeBuiltIn, dataSource: source, name: device.name, uid: device.uid
        )
        return OutputRoute(
            transport: fourCC(transport), isBuiltInSpeakers: speakers, key: "\(device.uid)|\(source.map(fourCC) ?? "none")"
        )
    }

    /// Calls `onChange` on `queue` when the default output device changes or the current one switches its data source
    /// (headphones plugged into the jack of a Mac that keeps one output device). `invalidate` before releasing it.
    final class OutputRouteWatcher {
        private let queue: DispatchQueue
        private let onChange: () -> Void
        private var device = AudioObjectID(kAudioObjectUnknown)
        private var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        private var sourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
        private var defaultListener: AudioObjectPropertyListenerBlock?
        private var sourceListener: AudioObjectPropertyListenerBlock?

        init(queue: DispatchQueue, onChange: @escaping () -> Void) {
            self.queue = queue
            self.onChange = onChange
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.watchSource()
                self?.onChange()
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue, listener) == noErr {
                defaultListener = listener
            }
            watchSource()
        }

        func invalidate() {
            if let defaultListener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue, defaultListener)
            }
            defaultListener = nil
            unwatchSource()
        }

        private func watchSource() {
            unwatchSource()
            guard let output = AudioDevices.defaultOutput() else { return }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
            if AudioObjectAddPropertyListenerBlock(output.id, &sourceAddress, queue, listener) == noErr {
                device = output.id
                sourceListener = listener
            }
        }

        private func unwatchSource() {
            if let sourceListener, device != kAudioObjectUnknown {
                AudioObjectRemovePropertyListenerBlock(device, &sourceAddress, queue, sourceListener)
            }
            sourceListener = nil
            device = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> Device? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown,
              let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
              let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
        return Device(id: id, uid: uid, name: name)
    }

    private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
