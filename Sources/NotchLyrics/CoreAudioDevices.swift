import Foundation
import CoreAudio

/// Lightweight CoreAudio enumeration. We don't try to be exhaustive — just enough
/// to populate input/output device pickers and recognize BlackHole when present.
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool

    var isBlackHole: Bool {
        let n = name.lowercased()
        return n.contains("blackhole")
    }
}

enum CoreAudioDevices {
    static func list() -> [AudioDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { deviceInfo(id: $0) }
    }

    /// UID of the device system audio is currently being sent to. Onboarding
    /// needs this to tell "loopback driver installed" apart from "loopback
    /// driver actually receiving audio".
    static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceInfo(id: AudioDeviceID) -> AudioDevice? {
        guard let name = stringProperty(id: id, selector: kAudioObjectPropertyName) else { return nil }
        let uid = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            hasInput:  hasStreams(id: id, scope: kAudioDevicePropertyScopeInput),
            hasOutput: hasStreams(id: id, scope: kAudioDevicePropertyScopeOutput)
        )
    }

    private static func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfStr as String
    }

    private static func hasStreams(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }
}
