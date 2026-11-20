import CoreAudio
import Foundation

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
