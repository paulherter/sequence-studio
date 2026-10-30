import CoreAudio
import Foundation

/// One audio output device as the Settings popup and `AudioEngine.setOutputDevice(uid:)` see it.
public struct AudioOutputDevice: Sendable, Hashable {
    public var uid: String
    public var name: String
    public var id: UInt32
    public init(uid: String, name: String, id: UInt32) { self.uid = uid; self.name = name; self.id = id }
}

public enum AudioOutputDevices {
    /// The device a stored UID selects: nil (= system default output) for no UID or a UID that is not connected
    /// (unplugged headphones, a setup moved to another Mac).
    public static func resolve(uid: String?, in devices: [AudioOutputDevice]) -> AudioOutputDevice? {
        guard let uid, !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// Output devices that exist right now (Core Audio HAL; at least one output stream).
    public static func available() -> [AudioOutputDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, id: id)
        }
    }

    /// The system default output device (HAL id), nil when there is none.
    public static func defaultDeviceID() -> UInt32? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}
